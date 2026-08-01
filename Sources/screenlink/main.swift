import AppKit
import Foundation

let config = Config.fromCommandLine()
if let logPath = config.logPath { Log.setFile(logPath) }

Log.info("screenlink starting")
Log.info("bundle: \(Bundle.main.bundlePath)")
Permissions.report()

if config.allowInput, !Permissions.hasAccessibility(prompt: false) {
    Log.warn("accessibility not granted; capture will work but input injection will be ignored")
}

/// Owns the objects that must outlive startup, and keeps AppKit as the run loop so the status item
/// stays responsive. `.accessory` keeps screenlink out of the Dock and the app switcher.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let application: Application
    private var menuBar: MenuBarController?

    init(application: Application) {
        self.application = application
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menuBar = MenuBarController(delegate: application)
        self.menuBar = menuBar
        application.onPairingRequest = { [weak menuBar] request in
            menuBar?.presentPairingRequest(request)
        }
        application.onPairingWithdrawn = { [weak menuBar] requestId in
            menuBar?.withdrawPairingRequest(requestId)
        }

        Task {
            do {
                try await application.start()
            } catch {
                Log.error("startup failed: \(error)")
                exit(1)
            }
        }
    }
}

let application = Application(config: config)
let delegate = AppDelegate(application: application)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
