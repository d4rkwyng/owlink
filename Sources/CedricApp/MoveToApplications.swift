import AppKit
import CedricCore

/// "Move Owlink to your Applications folder?" at launch, when Owlink runs
/// through App Translocation, from a mounted disk image, or as a download
/// outside Applications (AppLocation.offersMove). Sparkle can't update the
/// app from any of those. Move copies the app into Applications
/// (AppMover: the copy's signature is checked and only the copy loses its
/// quarantine), then quits and reopens from there. Not Now asks again next
/// launch; "Don't ask again" with Not Now stops asking (the
/// OwlinkMoveToApplicationsSuppressed user default).
///
/// Not in a check build (it runs from .build or dist/ by design), and only
/// once launch is done (after the first frame): the app is running, so
/// Gatekeeper has already passed it and the user has opened it.
@MainActor
enum MoveToApplications {
    static let suppressKey = "OwlinkMoveToApplicationsSuppressed"

    static func offerIfNeeded() {
        guard !DevEnvironment.checksEnabled,
              !UserDefaults.standard.bool(forKey: suppressKey)
        else { return }
        let location = AppLocation.current()
        guard location.offersMove else { return }
        offer(location)
    }

    private static func offer(_ location: AppLocation) {
        let source = Bundle.main.bundleURL
        let fs = LiveAppInstallFileSystem()
        let plan: AppMovePlan
        do {
            plan = try AppMovePlan.make(location: location, source: source,
                                        folders: AppLocation.applicationsFolders(), fs: fs)
        } catch {
            NSLog("Owlink: Move to Applications not offered: %@", String(describing: error))
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Move Owlink to your Applications folder?")
        alert.informativeText = explanation(location, plan)
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again")
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on && answer != .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard answer == .alertFirstButtonReturn else { return }

        var replace = false
        if plan.destinationExists && !plan.destinationIsOriginal {
            let ask = NSAlert()
            ask.messageText = String(localized: "Replace the Owlink in \(plan.folder.lastPathComponent)?")
            ask.informativeText = String(localized: "There is already an Owlink at \(plan.destination.path). It will go to the Trash.")
            ask.addButton(withTitle: String(localized: "Replace"))
            ask.addButton(withTitle: String(localized: "Cancel"))
            guard ask.runModal() == .alertFirstButtonReturn else { return }
            if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains(where: { $0.processIdentifier != getpid() && $0.bundleURL.map { AppMovePlan.same($0, plan.destination) } == true }) {
                report(String(localized: "The Owlink in \(plan.folder.lastPathComponent) is open. Quit it, then try again next launch."))
                return
            }
            replace = true
        }

        let outcome: AppMover.Outcome
        do {
            outcome = try AppMover(fs: fs).install(plan, replaceExisting: replace)
        } catch {
            report(String(localized: "Owlink couldn’t be moved to \(plan.folder.path): \(describe(error)). It keeps running from where it is."))
            return
        }
        if let left = outcome.originalLeftBehind {
            NSLog("Owlink: moved; the original at %@ couldn't go to the Trash", left.path)
        }
        relaunch(outcome.installed)
    }

    private static func explanation(_ location: AppLocation, _ plan: AppMovePlan) -> String {
        let why: String
        switch location {
        case .translocated:
            why = String(localized: "macOS is running Owlink from a temporary read-only copy (App Translocation), so Owlink can’t update itself.")
        case .diskImage:
            why = String(localized: "Owlink is running from the disk image, so it can’t update itself and goes away when the disk image is ejected.")
        default:
            why = String(localized: "Owlink is running from \(plan.source.deletingLastPathComponent().path), so it can’t update itself.")
        }
        return why + " " + String(localized: "Owlink can copy itself to \(plan.folder.path) and reopen from there.")
    }

    private static func describe(_ error: Error) -> String {
        switch error as? AppMoveError {
        case .copyFailed: return String(localized: "the copy failed")
        case .signatureInvalid: return String(localized: "the copy’s code signature didn’t check out")
        case .quarantineRemovalFailed: return String(localized: "the copy couldn’t be prepared")
        case .replaceFailed: return String(localized: "the Owlink already there couldn’t be replaced")
        case .noWritableApplicationsFolder: return String(localized: "no Applications folder Owlink can write to")
        case .destinationExists: return String(localized: "an Owlink is already there")
        case nil: return error.localizedDescription
        }
    }

    private static func report(_ text: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = String(localized: "Owlink wasn’t moved")
        a.informativeText = text
        a.runModal()
    }

    /// Quits and reopens the installed copy once this process is gone.
    private static func relaunch(_ app: URL) {
        let cmd = AppMover.relaunchCommand(pid: getpid(), app: app)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        do { try p.run() } catch {
            report(String(localized: "Owlink is now in \(app.deletingLastPathComponent().path). Quit and open it from there."))
            return
        }
        NSApp.terminate(nil)
        // Still here: the quit was cancelled (a save failed, Save As…).
        // The helper reopens the new copy if Owlink quits within a minute.
        report(String(localized: "Owlink is now in \(app.deletingLastPathComponent().path), but this window didn’t close. Quit Owlink and open it from there."))
    }
}
