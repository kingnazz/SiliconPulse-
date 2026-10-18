import Darwin
import Foundation
import IOKit

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size { return Int(Int32(truncatingIfNeeded: value)) }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

enum Clock {
    /// Monotonic nanoseconds (does not advance during sleep).
    static func uptimeNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// CPU time consumed by the calling thread.
    static func threadCPUNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}

enum IORegistry {
    /// Copies one property of a registry entry. Reading a single key is much cheaper than copying all properties.
    static func property(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func bytes(_ entry: io_registry_entry_t, _ key: String) -> [UInt8]? {
        guard let data = property(entry, key) as? Data else { return nil }
        return [UInt8](data)
    }

    /// Calls `body` for every service matching `className`, releasing each one afterwards.
    static func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            body(service)
            IOObjectRelease(service)
        }
    }

    static func forEachChild(of entry: io_registry_entry_t, plane: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            body(child)
            IOObjectRelease(child)
        }
    }

    static func number(_ value: Any?) -> NSNumber? { value as? NSNumber }
}
