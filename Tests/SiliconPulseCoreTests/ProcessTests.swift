import XCTest
@testable import SiliconPulseCore

final class ProcessTests: XCTestCase {
    private let processes: [ProcessSample] = [
        ProcessSample(pid: 1, parentPID: 0, name: "launchd", executablePath: "/sbin/launchd", uid: 0, userName: "root",
                      countersAvailable: false),
        ProcessSample(pid: 300, parentPID: 1, name: "WindowServer", executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                      uid: 88, userName: "_windowserver", countersAvailable: false),
        ProcessSample(pid: 500, parentPID: 1, name: "Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
                      isApp: true, bundleIdentifier: "com.apple.Safari", cpuPercent: 12, memoryFootprint: 900_000_000, threadCount: 40),
        ProcessSample(pid: 600, parentPID: 1, name: "ollama", executablePath: "/opt/homebrew/bin/ollama",
                      cpuPercent: 3, memoryFootprint: 200_000_000, threadCount: 20, diskReadBytesPerSecond: 1_000),
        ProcessSample(pid: 601, parentPID: 600, name: "ollama", executablePath: "/opt/homebrew/bin/ollama",
                      cpuPercent: 250, memoryFootprint: 18_000_000_000, threadCount: 30, diskReadBytesPerSecond: 50_000),
        ProcessSample(pid: 700, parentPID: 500, name: "Safari Web Content", cpuPercent: nil, memoryFootprint: 300_000_000),
    ]

    func testFilters() {
        let ai: Set<Int32> = [600, 601]
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(filter: .apps), to: processes).map(\.pid), [500])
        XCTAssertEqual(Set(ProcessTable.apply(ProcessQuery(filter: .system), to: processes).map(\.pid)), [1, 300])
        XCTAssertEqual(Set(ProcessTable.apply(ProcessQuery(filter: .ai), to: processes, aiPIDs: ai).map(\.pid)), ai)
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(filter: .highCPU), to: processes).map(\.pid), [601])
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(filter: .highMemory), to: processes).map(\.pid), [601])
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(filter: .all), to: processes).count, processes.count)
    }

    func testSearchMatchesNamePIDBundleAndPath() {
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(search: "safari", sortKey: .pid, ascending: true), to: processes).map(\.pid), [500, 700])
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(search: "601"), to: processes).map(\.pid), [601])
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(search: "com.apple.saf"), to: processes).map(\.pid), [500])
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(search: "homebrew", sortKey: .pid, ascending: true), to: processes).map(\.pid), [600, 601])
        XCTAssertEqual(ProcessTable.apply(ProcessQuery(search: "   "), to: processes).count, processes.count)
    }

    func testSortingPutsUnavailableValuesLastWhenDescending() {
        let byCPU = ProcessTable.sort(processes, by: .cpu, ascending: false)
        XCTAssertEqual(byCPU.prefix(3).map(\.pid), [601, 500, 600])
        XCTAssertTrue(byCPU.suffix(3).allSatisfy { $0.cpuPercent == nil })
        let byMemory = ProcessTable.sort(processes, by: .memory, ascending: false)
        XCTAssertEqual(byMemory.first?.pid, 601)
        let byName = ProcessTable.sort(processes, by: .name, ascending: true)
        XCTAssertEqual(byName.first?.name, "launchd")
    }

    func testSortIsStableForTies() {
        let tied = [ProcessSample(pid: 9, name: "b", cpuPercent: 1), ProcessSample(pid: 3, name: "a", cpuPercent: 1), ProcessSample(pid: 5, name: "c", cpuPercent: 1)]
        XCTAssertEqual(ProcessTable.sort(tied, by: .cpu, ascending: false).map(\.pid), [3, 5, 9])
    }

    func testTopSkipsRestricted() {
        let top = ProcessTable.top(processes, by: .cpu, limit: 2)
        XCTAssertEqual(top.map(\.pid), [601, 500])
    }

    func testProcessTreeDescendants() {
        let tree = ProcessTree(processes)
        XCTAssertEqual(Set(tree.children(of: 1)), [300, 500, 600])
        XCTAssertEqual(tree.descendants(of: 600), [601])
        XCTAssertEqual(Set(tree.descendants(of: 500)), [700])
        XCTAssertTrue(tree.descendants(of: 601).isEmpty)
    }

    func testProcessTreeSurvivesCycles() {
        let cyclic = [ProcessSample(pid: 10, parentPID: 11, name: "a"), ProcessSample(pid: 11, parentPID: 10, name: "b")]
        let tree = ProcessTree(cyclic)
        XCTAssertEqual(tree.descendants(of: 10), [11])
    }

    func testRuntimeAndSystemClassification() {
        let p = ProcessSample(pid: 42, name: "x", executablePath: "/usr/libexec/thing", uid: 501, startTime: 1_000)
        XCTAssertEqual(p.runtime(now: Date(timeIntervalSince1970: 1_090)), 90)
        XCTAssertTrue(p.isSystemProcess)
        XCTAssertFalse(ProcessSample(pid: 43, name: "y", executablePath: "/Applications/Y.app/Contents/MacOS/Y", uid: 501).isSystemProcess)
    }

    func testProcArgsParser() throws {
        var buffer: [UInt8] = []
        let argc: Int32 = 3
        withUnsafeBytes(of: argc.littleEndian) { buffer.append(contentsOf: $0) }
        func cString(_ s: String) { buffer.append(contentsOf: Array(s.utf8)); buffer.append(0) }
        cString("/opt/homebrew/bin/llama-server")
        buffer.append(contentsOf: [0, 0, 0])  // alignment padding
        cString("llama-server")
        cString("-m")
        cString("/models/Qwen3-30B-A3B-Q4_K_M.gguf")
        cString("HOME=/Users/me")
        cString("OLLAMA_HOST=127.0.0.1:11500")
        buffer.append(0)

        let result = try XCTUnwrap(ProcArgsParser.parse(buffer))
        XCTAssertEqual(result.executablePath, "/opt/homebrew/bin/llama-server")
        XCTAssertEqual(result.arguments, ["llama-server", "-m", "/models/Qwen3-30B-A3B-Q4_K_M.gguf"])
        XCTAssertEqual(result.environment["OLLAMA_HOST"], "127.0.0.1:11500")
        XCTAssertEqual(result.environment["HOME"], "/Users/me")
    }

    func testProcArgsParserRejectsGarbage() {
        XCTAssertNil(ProcArgsParser.parse([]))
        XCTAssertNil(ProcArgsParser.parse([1, 2]))
        XCTAssertNil(ProcArgsParser.parse([0xFF, 0xFF, 0xFF, 0x7F]))  // absurd argc, no data
        // argc larger than the strings present: returns what exists without crashing.
        var short: [UInt8] = [5, 0, 0, 0]
        short.append(contentsOf: Array("/bin/x".utf8) + [0] + Array("x".utf8) + [0])
        XCTAssertEqual(ProcArgsParser.parse(short)?.arguments, ["x"])
    }

    func testArgumentValueParsing() {
        let args = ["llama-server", "-m", "model.gguf", "--port=9000", "-c", "4096", "--metrics"]
        XCTAssertEqual(ArgumentParsing.value(in: args, flags: ["-m", "--model"]), "model.gguf")
        XCTAssertEqual(ArgumentParsing.value(in: args, flags: ["--port"]), "9000")
        XCTAssertEqual(ArgumentParsing.value(in: args, flags: ["-c", "--ctx-size"]), "4096")
        XCTAssertNil(ArgumentParsing.value(in: args, flags: ["--metrics"]), "flag at the end has no value")
        XCTAssertNil(ArgumentParsing.value(in: args, flags: ["--host"]))
    }

    func testAICandidateFilter() {
        XCTAssertTrue(AICandidateFilter.isCandidate(ProcessSample(pid: 1, name: "ollama")))
        XCTAssertTrue(AICandidateFilter.isCandidate(ProcessSample(pid: 1, name: "Python", executablePath: "/usr/bin/python3")))
        XCTAssertTrue(AICandidateFilter.isCandidate(ProcessSample(pid: 1, name: "llama-server", executablePath: "/opt/homebrew/bin/llama-server")))
        XCTAssertTrue(AICandidateFilter.isCandidate(ProcessSample(pid: 1, name: "LM Studio Helper", executablePath: "/Applications/LM Studio.app/Contents/Frameworks/LM Studio Helper.app/Contents/MacOS/LM Studio Helper")))
        XCTAssertFalse(AICandidateFilter.isCandidate(ProcessSample(pid: 1, name: "Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")))
        XCTAssertFalse(AICandidateFilter.isCandidate(ProcessSample(pid: 1, name: "server", executablePath: "/usr/local/bin/server")))
    }
}
