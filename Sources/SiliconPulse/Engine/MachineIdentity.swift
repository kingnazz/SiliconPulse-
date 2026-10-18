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
        let product = productName()
        // Screenshots may be shared: they show the model ("MacBook Pro"), not the owner's name for the Mac.
        let name = ScreenshotPrivacy.isActive
            ? ProcessInfo.processInfo.environment["SILICONPULSE_DISPLAY_NAME"] ?? product ?? "Mac"
            : (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        return MachineIdentity(computerName: name, modelName: product, osVersion: os)
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

/// Screenshot mode (`--screenshots`) produces images meant to be shared, so it leaves out who owns the Mac.
enum ScreenshotPrivacy {
    static let isActive = CommandLine.arguments.contains("--screenshots")

    /// The signed-in user's account name is shown as "you".
    static func userName(_ name: String) -> String {
        isActive && name == NSUserName() ? "you" : name
    }
}
