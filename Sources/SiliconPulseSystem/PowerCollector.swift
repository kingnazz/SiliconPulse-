import Foundation
import IOKit.ps
import SiliconPulseCore

/// Thermal pressure from `ProcessInfo` and power source state from IOPowerSources.
final class PowerCollector {
    func thermalLevel() -> ThermalLevel {
        ThermalLevel(processInfoRawValue: ProcessInfo.processInfo.thermalState.rawValue)
    }

    func power() -> PowerSnapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSnapshot(hasBattery: false, onACPower: true, batteryPercent: nil, isCharging: false, lowPowerMode: lowPower)
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = providing.map { $0 == kIOPSACPowerValue } ?? true
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerSnapshot(hasBattery: false, onACPower: onAC, batteryPercent: nil, isCharging: false, lowPowerMode: lowPower)
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent: Int? = {
                guard let current, let maximum, maximum > 0 else { return nil }
                return Int((current / maximum * 100).rounded())
            }()
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let state = description[kIOPSPowerSourceStateKey] as? String
            return PowerSnapshot(hasBattery: true, onACPower: state.map { $0 == kIOPSACPowerValue } ?? onAC,
                                 batteryPercent: percent, isCharging: charging, lowPowerMode: lowPower)
        }
        return PowerSnapshot(hasBattery: false, onACPower: onAC, batteryPercent: nil, isCharging: false, lowPowerMode: lowPower)
    }
}
