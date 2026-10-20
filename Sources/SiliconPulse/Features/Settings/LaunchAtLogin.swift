import ServiceManagement
import SwiftUI

/// "Open at login" through ServiceManagement's main-app login item (macOS 13+). macOS owns the state:
/// it is read back from `SMAppService` rather than stored, so it stays right if the user changes it
/// in System Settings › General › Login Items.
struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open SiliconPulse at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { set($0) }))
            if status == .requiresApproval {
                HStack(spacing: 6) {
                    Text("macOS needs your approval in Login Items.").foregroundStyle(.secondary)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.caution)
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Could not change the login item: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}
