# Awake

A macOS menu bar app that keeps your Mac from sleeping for a set duration.

Menu-bar only — no Dock icon, no main window, no third-party dependencies.

---

## If your Mac won't sleep and you want it back now

Awake restores normal sleep on stop, expiry, quit, crash, and force-quit. If
something still goes wrong, this always fixes it:

```sh
sudo pmset -a disablesleep 0
```

Then confirm it took:

```sh
pmset -g | grep SleepDisabled
```

No output, or `0`, means normal sleep is back. Note that `pmset -g assertions`
does **not** show this flag — only `pmset -g` does.

To check whether anything is holding sleep open:

```sh
pmset -g assertions | grep Awake
```

---

## Two sleep paths, two mechanisms

macOS sleeps for two independent reasons, and they need different overrides.

**Idle sleep** — no input for a while. Blocked with IOKit power assertions
(`kIOPMAssertionTypePreventUserIdleSystemSleep`, plus
`kIOPMAssertionTypePreventUserIdleDisplaySleep` when "Display" is on). This
needs no privileges and is what the app does today.

**Clamshell sleep** — the lid switch fires and the system suspends immediately.
Power assertions do **not** block this. Without an external display the only
override is the undocumented system `SleepDisabled` flag
(`pmset -a disablesleep`), which requires root — hence a privileged helper.

Assertions are per-process, so the kernel reclaims them if Awake is killed.
`SleepDisabled` is global system state that **survives the process**, which is
why launch-time recovery exists (see below).

---

## Status

| Capability | State |
|---|---|
| Idle sleep prevention | Working |
| Display sleep toggle | Working |
| Duration dial, presets, countdown | Working |
| Timer expiry, manual stop, quit, force-quit teardown | Working |
| Battery floor | Working |
| Expiry / battery notifications | Working |
| Launch-time `SleepDisabled` recovery | Working (detection needs no helper) |
| **Lid-closed override** | **Not installable — see below** |

The lid-closed capability is fully modelled — protocol, mock, session wiring,
UI, degrade path, tests — but the privileged daemon that performs the write is
not built, because it cannot be registered on a machine with no Developer ID.

Turning the **Lid** chip on today starts the session with idle-sleep prevention
only and says so, both in the popover and in the `⋯` menu. It never silently
pretends the capability is active.

---

## Build and run

Requires the Swift toolchain (Command Line Tools is enough; Xcode is not
needed).

```sh
swift build                 # compile
swift run AwakeTests        # run the checks
./bundle.sh                 # assemble .build/Awake.app
./install.sh                # build release, install to /Applications, launch
```

You need macOS 14 or later to run it, and the app is **not notarized** — see
Distribution below before handing the built `.app` to anyone.

### Why SwiftPM and not XcodeGen

The project is a plain `Package.swift` with no dependencies, and `bundle.sh`
assembles the `.app` by hand, so it builds with only the Command Line Tools —
no Xcode, no XcodeGen, nothing to install first.

### Why the checks aren't XCTest

The Command Line Tools toolchain ships neither `XCTest` nor `swift-testing`, so
`swift test` cannot work there at all. `Tests/AwakeTests` is a plain executable
with a 26-line `expect`/`expectEqual` harness that exits non-zero on failure.

```sh
swift run AwakeTests            # all checks
swift run AwakeTests --render   # write popover snapshots + palette to tmp/
```

---

## Using it

Click the menu bar icon.

- **Drag the ring** to set a duration. One sweep covers 5 minutes to 12 hours on
  a curve — fine steps under an hour, coarse above. Hold <kbd>⌥</kbd> for finer
  steps. Arrow keys work too.
- **Preset chips** (`15m` … `4h`, `∞`) start immediately and become the dial's
  remembered value.
- **Display** keeps the screen on as well, which also holds off the screensaver.
- **Lid** asks for the lid-closed override (see Status).
- **⋯** has launch at login, expiry notifications, and the battery floor.

Keyboard: <kbd>1</kbd>–<kbd>5</kbd> presets, <kbd>0</kbd> indefinite,
<kbd>Return</kbd> start the dial's value, <kbd>E</kbd> add 15 minutes,
<kbd>.</kbd> stop, <kbd>⌘Q</kbd> quit.

The ring's colour is the time of day the session ends — night indigo through
dawn amber, midday sky, sunset coral. It's a second channel, never the only one:
the end time is always shown as text.

---

## Installing the lid-closed helper

**Not possible with the default ad-hoc build.**
`SMAppService.daemon(plistName:)` requires the app bundle to carry a valid
signing identity, and `bundle.sh` signs ad-hoc (`codesign --sign -`). An ad-hoc
signature has no Team ID, so there is nothing stable for the daemon's XPC
listener to validate clients against — the cdhash changes on every build.

Check what you have with:

```sh
security find-identity -v -p codesigning
```

To finish it you need:

1. An Apple Developer ID certificate.
2. A `LidHelper` executable at `Contents/MacOS/`, and its launchd plist at
   `Contents/Library/LaunchDaemons/com.vishwam.Awake.LidHelper.plist`.
3. `bundle.sh` changed to sign with the Developer ID instead of `-`.
4. The helper's `NSXPCListener` validating each client with
   `SecCodeCheckValidityWithErrors` against a requirement pinning your Team ID.

The helper's entire job is `/usr/bin/pmset -a disablesleep 0|1` and reading
`pmset -g` back. It accepts a boolean over XPC and nothing else — no paths, no
arguments, no command strings.

### Safety invariants

- `SleepDisabled` is read back after every write; a write that didn't take is
  reported, never assumed.
- Restored on timer expiry, manual stop, app quit, and any thrown error.
- On launch, if `SleepDisabled` is set with no session running, a previous run
  was killed before restoring it — Awake puts it back and tells you. Detection
  works without the helper, since reading needs no privileges.
- Lid-closed sessions always require a finite timer. Indefinite + lid-closed is
  refused and downgraded.
- Battery floor (default 20%, range 10–50%) ends the session when charge drops
  below it, with a notification about 10 minutes ahead.

### Heat

A Mac kept awake with the lid shut in an enclosed bag gets hot. That is why
lid-closed sessions must have a timer, and why the battery floor exists.

---

## Layout

```
Sources/AwakeCore/
  AwakeApp.swift            MenuBarExtra scene, menu bar label
  PopoverView.swift         the popover
  DurationDial.swift        draggable dial + DialMath (pure, checked)
  ProgressRing.swift        running-state ring, button style, Motion
  DayPalette.swift          time-of-day colour system
  Session.swift             session state machine, battery floor, teardown
  SleepPreventing.swift     IOKit assertions (+ mock)
  LidSleepOverriding.swift  lid-closed protocol, pmset reader (+ mock)
  LidHelperClient.swift     XPC client for the privileged daemon
  Battery.swift             IOPS charge + time-to-floor estimate
  Notifier.swift            UNUserNotificationCenter wrapper
  TimeFormat.swift          menu bar / countdown / duration formatting
Sources/Awake/main.swift    @main entry point
Tests/AwakeTests/           check harness and checks
```

`AwakeCore` is a library and `Awake` a thin executable because a test target
cannot link a target that owns `@main`.

---

## Distribution

**Build from source works; handing someone the built `.app` does not.**

`bundle.sh` signs ad-hoc, so the app has no Team ID and no notarization ticket:

```sh
$ spctl -a -vv /Applications/Awake.app
/Applications/Awake.app: rejected
```

It runs on the machine that built it because locally-built files are never
quarantined. A copy downloaded from GitHub gets `com.apple.quarantine` attached
and Gatekeeper refuses to launch it. A recipient would have to run:

```sh
xattr -dr com.apple.quarantine /Applications/Awake.app
```

which is a thing you should not ask strangers to do. **Clone and build** is the
supported route until the app is signed with a Developer ID and notarized.

Not sandboxed — the lid-closed helper rules out the App Sandbox and therefore
the Mac App Store. The intended path is Developer ID + notarization.

## Licence

MIT — see [LICENSE](LICENSE).
