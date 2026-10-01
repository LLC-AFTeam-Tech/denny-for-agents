import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while a local agent works, so a long task
/// isn't cut off when you step away. The display may still sleep.
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private(set) var isHolding = false

    func update(shouldHold: Bool) {
        if shouldHold, !isHolding {
            let reason = "Denny for Agents: keeping the Mac awake" as CFString
            isHolding = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertion
            ) == kIOReturnSuccess
        } else if !shouldHold, isHolding {
            IOPMAssertionRelease(assertion)
            isHolding = false
        }
    }

    deinit {
        update(shouldHold: false)
    }
}

/// "Keep going with the lid closed": macOS sleeps on lid close no matter
/// what an app asks, unless `pmset disablesleep 1` is set, which needs root.
/// Denny installs, once and with your admin password, a sudoers rule that
/// allows exactly two commands — `pmset -a disablesleep 1` and `… 0` — and
/// nothing else. It only turns it on while on the charger and always turns
/// it back off: when the work is done, on quit, and on the next launch if
/// the app ever crashed with it on.
final class LidSleepGuard {
    static let sudoersPath = "/etc/sudoers.d/denny-for-agents"
    private static let markerKey = "lidSleepDisabledByDenny"
    private static let rule = "%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"

    private(set) var isDisabled = UserDefaults.standard.bool(forKey: LidSleepGuard.markerKey)

    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.sudoersPath) }

    static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMACPowerKey
    }

    /// Asks for the admin password once and installs the narrow rule.
    func install() -> Bool {
        let shell = """
        f=$(/usr/bin/mktemp) && echo '\(Self.rule)' > "$f" && /usr/sbin/visudo -cf "$f" && \
        /usr/bin/install -m 0440 -o root -g wheel "$f" \(Self.sudoersPath); rc=$?; /bin/rm -f "$f"; exit $rc
        """
        return Self.runAsAdmin(shell)
    }

    /// Removes the rule (asks for the password again).
    func uninstall() {
        set(false)
        guard isInstalled else { return }
        _ = Self.runAsAdmin("/bin/rm -f \(Self.sudoersPath)")
    }

    /// Applies the wanted state; only runs pmset when it changes.
    func set(_ disabled: Bool) {
        guard disabled != isDisabled, isInstalled || !disabled else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }
        isDisabled = disabled
        UserDefaults.standard.set(disabled, forKey: Self.markerKey)
    }

    /// After a crash the Mac could be left unable to sleep on lid close.
    func restoreIfNeeded() {
        if UserDefaults.standard.bool(forKey: Self.markerKey) {
            isDisabled = true
            set(false)
        }
    }

    private static func runAsAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }
}
