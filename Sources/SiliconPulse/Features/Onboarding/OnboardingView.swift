import SwiftUI

/// First launch: one screen, one button.
struct OnboardingView: View {
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.cpu)
            VStack(spacing: 8) {
                Text("SiliconPulse")
                    .font(.system(size: 30, weight: .semibold))
                Text("See what your Mac is really doing.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text("Everything stays on this Mac.")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            Button(action: onStart) {
                Text("Start Monitoring").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
            Spacer()
            Text("No account, no telemetry, no uploads.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
