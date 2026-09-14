import ServiceManagement
import SwiftUI

public struct PopoverView: View {
    @ObservedObject var session: SessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage("keepDisplayAwake") private var keepDisplayAwake = true
    @AppStorage("customMinutes") private var customMinutes = 90
    @AppStorage("allowLidClosed") private var allowLidClosed = false
    @AppStorage("batteryFloor") private var batteryFloor = 20
    @AppStorage("notifyOnExpiry") private var notifyOnExpiry = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private static let presets: [TimeInterval] = [15 * 60, 30 * 60, 3600, 2 * 3600, 4 * 3600]
    private var motion: Motion { Motion(reduced: reduceMotion) }

    public init(session: SessionController) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                if session.isRunning {
                    running.transition(motion.transition)
                } else {
                    idle.transition(motion.transition)
                }
            }
            .padding(16)
        }
        .frame(width: 276)
        // Near-opaque panel over the menu bar window's material. The default material
        // is translucent enough that desktop and window content shows through, which
        // fights the ring for attention — colour is supposed to be the only signal.
        // No background wash either: the field stays monochrome so the ring is the
        // one saturated thing in view.
        .background(panel)
        // Suppressed at container level: applying it directly to the dial also takes
        // the dial out of the key-event path, which kills arrow-key adjustment.
        .focusEffectDisabled()
        // ⌘Q lives in the ⋯ menu, so bind it here to keep it working popover-wide.
        .background {
            Button("") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .hidden()
        }
        .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }
        .onChange(of: batteryFloor) { _, value in session.batteryFloor = value }
        .onChange(of: notifyOnExpiry) { _, value in session.notifyOnExpiry = value }
        .onAppear {
            session.batteryFloor = batteryFloor
            session.notifyOnExpiry = notifyOnExpiry
        }
        .animation(motion.spring, value: session.isRunning)
    }

    private var panel: Color {
        let base = colorScheme == .dark
            ? Color(red: 0.09, green: 0.09, blue: 0.10)
            : Color(red: 0.96, green: 0.96, blue: 0.97)
        // A sliver of vibrancy at the edges unless the user asked for none at all.
        return base.opacity(reduceTransparency ? 1 : 0.97)
    }

    // MARK: - Idle

    private var idle: some View {
        VStack(spacing: 9) {
            // No header: you just clicked the app's own icon, so naming the app here
            // would only cost vertical space. The dial *is* the interface.
            //
            // A circle in a full-width column wastes ~78pt either side, so the presets
            // live in that margin instead of under it — kills the dead space and the
            // row of height it used to occupy.
            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    DurationDial(minutes: $customMinutes, motion: motion, now: context.date)
                }
                .help("Drag the ring to set a duration — hold ⌥ for finer steps")

                presetGrid
            }

            Button("Start \(TimeFormat.duration(TimeInterval(customMinutes) * 60))") {
                start(duration: TimeInterval(customMinutes) * 60)
            }
            .buttonStyle(LiftButtonStyle(
                prominent: true, fill: button(dialEndColor).color, ink: button(dialEndColor).ink, motion: motion
            ))
            // Tab only reaches buttons when Full Keyboard Access is on, so bind Return
            // directly — otherwise the dial is adjustable but not startable.
            .keyboardShortcut(.defaultAction)

            utilityRow

            if allowLidClosed && !session.lidAvailable {
                Label("Lid-closed needs the helper — not installed, so idle sleep only.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(motion.transition)
            }
        }
    }

    /// Presets, two across, filling the margin beside the dial. Row-major order keeps
    /// them ascending left-to-right. Deliberately monochrome — six tinted chips next
    /// to a coloured ring was the thing that made the panel feel busy.
    private var presetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 2),
            spacing: 5
        ) {
            ForEach(Array(Self.presets.enumerated()), id: \.element) { index, seconds in
                PresetChip(title: TimeFormat.duration(seconds), wash: nil, motion: motion) {
                    start(duration: seconds)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [])
                .accessibilityLabel("Stay awake for \(TimeFormat.duration(seconds))")
            }
            // Indefinite is just another duration choice, so it sits with the rest
            // rather than owning a button of its own.
            PresetChip(title: "∞", wash: nil, motion: motion) { start(duration: nil) }
                .keyboardShortcut("0", modifiers: [])
                .help("Stay awake until I turn it off")
                .accessibilityLabel("Stay awake until I turn it off")
        }
    }

    /// Display toggle plus everything secondary, in one 24pt row.
    private var utilityRow: some View {
        HStack(spacing: 6) {
            Button { keepDisplayAwake.toggle() } label: {
                Label("Display", systemImage: keepDisplayAwake ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(LiftButtonStyle(
                fill: keepDisplayAwake ? Color(red: 0.85, green: 0.66, blue: 0.36) : nil,
                ink: keepDisplayAwake ? Color(red: 0.85, green: 0.66, blue: 0.36) : .secondary,
                padding: 4, stretch: false, motion: motion
            ))
            .help("Keep the display awake too")
            .accessibilityLabel("Keep display awake")
            .accessibilityValue(keepDisplayAwake ? "on" : "off")

            Button { allowLidClosed.toggle() } label: {
                Label("Lid", systemImage: allowLidClosed ? "laptopcomputer.and.arrow.down" : "laptopcomputer")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(LiftButtonStyle(
                fill: allowLidClosed ? Color(red: 0.45, green: 0.62, blue: 0.85) : nil,
                ink: allowLidClosed ? Color(red: 0.45, green: 0.62, blue: 0.85) : .secondary,
                padding: 4, stretch: false, motion: motion
            ))
            .help(lidHelpText)
            .accessibilityLabel("Keep running with the lid closed")
            .accessibilityValue(allowLidClosed ? "on" : "off")

            Spacer()

            Menu {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Notify when a session ends", isOn: $notifyOnExpiry)
                Picker("Stop below battery", selection: $batteryFloor) {
                    ForEach([10, 15, 20, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                Divider()
                Text(lidAvailabilityText)
                Divider()
                Button("Quit Awake") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More options")
        }
    }

    private var lidHelpText: String {
        session.lidAvailable
            ? "Keep running with the lid closed. Needs a finite timer. Watch heat in a bag."
            : "Needs the privileged helper, which isn't installed — sessions will prevent idle sleep only."
    }

    private var lidAvailabilityText: String {
        session.lidAvailable ? "Lid-closed helper: installed" : "Lid-closed helper: not installed"
    }

    /// Fill for a primary button. Dimmed on dark so it sits below the ring in the
    /// visual hierarchy; `ink` then resolves to a light label automatically.
    private func button(_ base: DayColor) -> DayColor {
        colorScheme == .dark ? base.muted.dimmed(0.42) : base.muted
    }

    /// Colour of the moment the dial currently points at — drives Start.
    private var dialEndColor: DayColor {
        DayPalette.dayColor(at: Date().addingTimeInterval(TimeInterval(customMinutes) * 60))
    }

    // MARK: - Running

    private var running: some View {
        VStack(spacing: 10) {
            ZStack {
                ProgressRing(
                    progress: session.progress,
                    from: DayPalette.dayColor(at: Date()).muted.color,
                    to: runningEndColor.muted.color,
                    spinning: isIndefinite,
                    reduceMotion: reduceMotion
                )
                .animation(motion.sweep, value: session.progress)

                VStack(spacing: 1) {
                    Text(countdownText)
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        // H:MM:SS is wider than the ring's inner diameter — shrink to
                        // fit rather than letting it collide with the stroke.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(motion.snappy, value: session.remaining)
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(runningEndColor.muted.color)
                }
                .padding(.horizontal, 16)  // keep the readout clear of the stroke
            }
            .frame(width: 104, height: 104)

            Text(sessionSummary)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 6) {
                if !isIndefinite {
                    Button("+15 min") { session.extend(by: 15 * 60) }
                        .buttonStyle(LiftButtonStyle(
                            prominent: true, fill: button(runningEndColor).color,
                            ink: button(runningEndColor).ink, motion: motion
                        ))
                        .keyboardShortcut("e", modifiers: [])
                        .accessibilityLabel("Add 15 minutes")
                }
                Button("Stop") { session.stop() }
                    .buttonStyle(LiftButtonStyle(ink: .red, motion: motion))
                    .keyboardShortcut(".", modifiers: [])
            }

            utilityRow
        }
    }

    private var isIndefinite: Bool { session.state.endDate == nil }

    /// Fixed for the life of a session — the end time doesn't move, so nor does the hue.
    private var runningEndColor: DayColor {
        DayPalette.dayColor(at: session.state.endDate ?? Date())
    }

    private var countdownText: String {
        isIndefinite ? "∞" : TimeFormat.countdown(remaining: session.remaining)
    }

    private var subtitle: String {
        guard let end = session.state.endDate else { return "no time limit" }
        return "until \(TimeFormat.endTime(end))"
    }

    /// "45m session · 3m in" — gives the countdown a sense of scale.
    private var sessionSummary: String {
        guard !isIndefinite, session.totalDuration > 0 else { return "running until you stop it" }
        let elapsed = session.totalDuration - session.remaining
        return "\(TimeFormat.duration(session.totalDuration)) session · \(TimeFormat.duration(max(60, elapsed))) in"
    }

    // MARK: - Actions

    private func start(duration: TimeInterval?) {
        // Remember a preset as the dial's value so next time it's already there.
        if let duration { customMinutes = Int(duration) / 60 }
        let options = SessionOptions(
            keepDisplayAwake: keepDisplayAwake,
            allowLidClosed: allowLidClosed && duration != nil
        )
        Task { await session.start(duration: duration, options: options) }
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        do {
            wanted ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            session.lastError = "Couldn't change launch at login: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PresetChip: View {
    let title: String
    let wash: Color?
    let motion: Motion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .buttonStyle(LiftButtonStyle(fill: wash, padding: 7, motion: motion))
    }
}
