import Darwin
import Foundation
import SiliconPulseCore

/// Identity of a running GUI app, supplied by the main thread from NSWorkspace.
public struct RunningAppInfo: Sendable, Equatable {
    public var name: String
    public var bundleIdentifier: String?
    public var isRegularApp: Bool

    public init(name: String, bundleIdentifier: String?, isRegularApp: Bool) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isRegularApp = isRegularApp
    }
}

/// Process table from one `sysctl(KERN_PROC_ALL)` plus per-process `libproc` counters.
/// Static facts (path, user, architecture) are cached per PID + start time; buffers are reused across samples.
final class ProcessCollector {
    private struct StaticInfo {
        var path: String?
        var baseName: String
        var userName: String
        var architecture: ProcessArchitecture
    }

    private struct Counters {
        var cpuNanoseconds: UInt64
        var diskRead: UInt64
        var diskWritten: UInt64
        var time: UInt64
    }

    private var kinfoBuffer: [kinfo_proc] = []
    private var staticCache: [ProcessIdentity: StaticInfo] = [:]
    private var previous: [ProcessIdentity: Counters] = [:]
    private var userNames: [uid_t: String] = [:]
    private var argumentCache: [ProcessIdentity: ProcArgsParser.Result] = [:]
    private var argumentBuffer: [UInt8] = []
    private let timebase: mach_timebase_info_data_t
    private let myUID = getuid()
    private let isRoot = geteuid() == 0
    let ownPID = getpid()

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    func sample(now: UInt64, apps: [Int32: RunningAppInfo], gpuShares: [Int32: Double]) -> [ProcessSample] {
        let entries = listProcesses()
        var result: [ProcessSample] = []
        result.reserveCapacity(entries.count)
        var seen = Set<ProcessIdentity>()
        seen.reserveCapacity(entries.count)

        for entry in entries {
            let pid = entry.kp_proc.p_pid
            if Int32(entry.kp_proc.p_stat) == SZOMB { continue }
            let start = entry.kp_proc.p_un.__p_starttime
            let startTime = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
            let identity = ProcessIdentity(pid: pid, startTime: startTime)
            seen.insert(identity)
            let uid = entry.kp_eproc.e_ucred.cr_uid
            let info = staticInfo(for: identity, entry: entry, uid: uid)
            let app = apps[pid]

            var sample = ProcessSample(pid: pid, parentPID: entry.kp_eproc.e_ppid,
                                       name: app?.name ?? info.baseName, executablePath: info.path,
                                       uid: uid, userName: info.userName, startTime: startTime,
                                       architecture: info.architecture, isApp: app?.isRegularApp ?? false,
                                       bundleIdentifier: app?.bundleIdentifier, countersAvailable: false,
                                       gpuTimeShare: gpuShares[pid])

            if pid != 0 && (isRoot || uid == myUID) {
                readCounters(into: &sample, identity: identity, now: now)
            }
            result.append(sample)
        }

        // Forget processes that exited.
        if staticCache.count > seen.count + 64 || previous.count > seen.count {
            staticCache = staticCache.filter { seen.contains($0.key) }
            previous = previous.filter { seen.contains($0.key) }
            argumentCache = argumentCache.filter { seen.contains($0.key) }
        }
        return result
    }

    private func readCounters(into sample: inout ProcessSample, identity: ProcessIdentity, now: UInt64) {
        let pid = sample.pid
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { return }

        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }

        let cpu = ProcessCPUCalculator.nanoseconds(machUnits: task.pti_total_user &+ task.pti_total_system,
                                                   numer: timebase.numer, denom: timebase.denom)
        sample.countersAvailable = true
        sample.cpuTimeNanoseconds = cpu
        sample.threadCount = Int(task.pti_threadnum)

        var diskRead: UInt64 = 0
        var diskWritten: UInt64 = 0
        if usageResult == 0 {
            sample.memoryFootprint = usage.ri_phys_footprint
            diskRead = usage.ri_diskio_bytesread
            diskWritten = usage.ri_diskio_byteswritten
            sample.diskReadTotal = diskRead
            sample.diskWrittenTotal = diskWritten
        } else {
            sample.memoryFootprint = task.pti_resident_size
        }

        if let old = previous[identity], now > old.time {
            let elapsed = now - old.time
            sample.cpuPercent = ProcessCPUCalculator.percent(previousCPUNanoseconds: old.cpuNanoseconds, currentCPUNanoseconds: cpu,
                                                             elapsedNanoseconds: elapsed)
            if usageResult == 0 {
                let seconds = Double(elapsed) / 1e9
                sample.diskReadBytesPerSecond = CounterRate.perSecond(previous: old.diskRead, current: diskRead, elapsed: seconds)
                sample.diskWriteBytesPerSecond = CounterRate.perSecond(previous: old.diskWritten, current: diskWritten, elapsed: seconds)
            }
        }
        previous[identity] = Counters(cpuNanoseconds: cpu, diskRead: diskRead, diskWritten: diskWritten, time: now)
    }

    private func listProcesses() -> ArraySlice<kinfo_proc> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }
            let needed = size / stride + 32
            if kinfoBuffer.count < needed {
                kinfoBuffer = [kinfo_proc](repeating: kinfo_proc(), count: needed + needed / 4)
            }
            size = kinfoBuffer.count * stride
            let status = kinfoBuffer.withUnsafeMutableBufferPointer { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if status == 0 { return kinfoBuffer[0..<(size / stride)] }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    private func staticInfo(for identity: ProcessIdentity, entry: kinfo_proc, uid: uid_t) -> StaticInfo {
        if let cached = staticCache[identity] { return cached }
        let pid = identity.pid
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil
        let comm = withUnsafeBytes(of: entry.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        var baseName = path.map { ($0 as NSString).lastPathComponent } ?? comm
        if baseName.isEmpty { baseName = pid == 0 ? "kernel_task" : comm }
        let translated = (entry.kp_proc.p_flag & P_TRANSLATED) != 0
        #if arch(arm64)
        let architecture: ProcessArchitecture = translated ? .rosetta : .appleSilicon
        #else
        let architecture: ProcessArchitecture = .intel
        #endif
        let info = StaticInfo(path: path, baseName: baseName, userName: userName(uid), architecture: architecture)
        staticCache[identity] = info
        return info
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userNames[uid] { return cached }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        let name: String
        if getpwuid_r(uid, &pwd, &buffer, buffer.count, &result) == 0, result != nil, let raw = pwd.pw_name {
            name = String(cString: raw)
        } else {
            name = String(uid)
        }
        userNames[uid] = name
        return name
    }

    // MARK: On-demand detail (inspector and AI candidates only)

    /// Launch arguments and environment via `KERN_PROCARGS2`. Cached for the life of the process.
    func arguments(for identity: ProcessIdentity) -> ProcArgsParser.Result? {
        if let cached = argumentCache[identity] { return cached }
        let max = Sysctl.int("kern.argmax") ?? 262_144
        if argumentBuffer.count < max { argumentBuffer = [UInt8](repeating: 0, count: max) }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, identity.pid]
        var size = argumentBuffer.count
        let status = argumentBuffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0, size > 0, let parsed = ProcArgsParser.parse(Array(argumentBuffer[0..<size])) else { return nil }
        argumentCache[identity] = parsed
        return parsed
    }

    /// TCP sockets in LISTEN state owned by the process.
    func listeningSockets(pid: Int32) -> [ListeningSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 8)
        let used = fds.withUnsafeMutableBufferPointer { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count * stride)) }
        guard used > 0 else { return [] }
        var sockets = Set<ListeningSocket>()
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard Int(info.psi.soi_kind) == Int(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard Int(tcp.tcpsi_state) == Int(TSI_S_LISTEN) else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            sockets.insert(ListeningSocket(address: Self.localAddress(tcp.tcpsi_ini), port: port))
        }
        return sockets.sorted { ($0.port, $0.address) < ($1.port, $1.address) }
    }

    private static func localAddress(_ ini: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if (ini.insi_vflag & UInt8(INI_IPV4)) != 0 {
            var address = ini.insi_laddr.ina_46.i46a_addr4
            if address.s_addr == 0 { return "*" }
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        } else {
            var address = ini.insi_laddr.ina_6
            let isAny = withUnsafeBytes(of: address) { $0.allSatisfy { $0 == 0 } }
            if isAny { return "*" }
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
        }
        return String(cString: buffer)
    }

    func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    func openFileCount(pid: Int32) -> Int? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        return bytes > 0 ? Int(bytes) / MemoryLayout<proc_fdinfo>.stride : nil
    }
}
