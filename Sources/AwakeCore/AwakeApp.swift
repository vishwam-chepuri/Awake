import SwiftUI

public struct AwakeApp: App {
    @StateObject private var session = SessionController(
        preventer: IOKitSleepPreventer(),
        lid: HelperLidSleepOverride()
    )

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            PopoverView(session: session)
                .task {
                    // Safety invariant: if SleepDisabled is still set with no session
                    // running, a previous run was killed before it could restore it.
                    await session.recoverStaleLidOverrideIfNeeded()
                    Notifier.requestAuthorization()
                }
        } label: {
            MenuBarLabel(session: session)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var session: SessionController

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: session.iconName)
                .symbolEffect(.bounce, value: session.isRunning)
            if !session.menuBarLabel.isEmpty {
                // Monospaced digits so the item width doesn't jitter as it counts down.
                Text(session.menuBarLabel).monospacedDigit()
            }
        }
        // Without this VoiceOver reads the SF Symbol's own name ("Snooze").
        .accessibilityLabel(session.accessibilityLabel)
    }
}
