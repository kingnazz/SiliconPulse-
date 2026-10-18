import Foundation
import IOKit
import SystemConfiguration

/// Static facts that identify this Mac in the Overview header. Read once.
struct MachineIdentity: Equatable {
    /// The user's name for this Mac ("Naz's Mac Studio").
    var computerName: String
    /// Marketing model name from the device tree ("Mac Studio (2025)"), when available.
    var modelName: String?
    var osVersion: String

    static let current: MachineIdentity = {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        return MachineIdentity(computerName: name, modelName: productName(), osVersion: os)
    }()

    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: value.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
