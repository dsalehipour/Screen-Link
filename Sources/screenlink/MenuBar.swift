import AppKit
import CoreImage

struct MenuBarState {
    var url: String
    var networkEnabled: Bool
    var capturing: Bool
    var accessibility: Bool
    var viewers: Int
    var fingerprint: String?
    var displayName: String
    var devices: [PairedDevice]
    var tunnel: TunnelController.State
    var tunnelInstalled: Bool

    var tunnelActive: Bool {
        switch tunnel {
        case .running, .starting: return true
        case .off, .failed: return false
        }
    }
}

protocol MenuBarDelegate: AnyObject {
    func menuBarState() -> MenuBarState
    func menuBarSetNetworkAccess(_ enabled: Bool)
    func menuBarRotateToken()
    func menuBarSetTunnel(_ enabled: Bool)
    func menuBarResolvePairing(requestId: String, approved: Bool)
    func menuBarRevokeDevice(_ deviceId: String)
    func menuBarRevokeAllDevices()
}

/// The status-bar surface.
///
/// Everything a person needs to get their phone connected lives here, because the alternative is a
/// terminal, and a product that requires a terminal is not a product.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var delegate: MenuBarDelegate?
    private var refreshTimer: Timer?
    /// Requests queued behind the one on screen, and the one being shown.
    private var waiting: [PairingRequest] = []
    private var presenting: PairingRequest?

    init(delegate: MenuBarDelegate) {
        self.delegate = delegate
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "display",
                                           accessibilityDescription: "screenlink")
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // The viewer count is the one thing that must be visible without opening the menu: it is
        // how you notice someone is watching.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        refreshTitle()
        Log.info("menu bar item ready\(statusItem.button == nil ? " (no button — status bar full?)" : "")")
    }

    private func refreshTitle() {
        guard let state = delegate?.menuBarState() else { return }
        statusItem.button?.title = state.viewers > 0 ? " \(state.viewers)" : ""
        statusItem.button?.contentTintColor = state.viewers > 0 ? .systemGreen : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let state = delegate?.menuBarState() else { return }

        switch state.tunnel {
        case .running:
            addQRSection(to: menu, state: state)
            menu.addItem(caption("Reachable from anywhere. Cloudflare can see this screen."))
        case .starting:
            menu.addItem(header("Opening internet link…"))
            menu.addItem(caption("Waiting for Cloudflare to assign an address."))
        case .failed(let reason):
            menu.addItem(header("Internet link failed"))
            menu.addItem(caption(reason))
        case .off:
            if state.networkEnabled {
                addQRSection(to: menu, state: state)
            } else {
                addLocalOnlySection(to: menu)
            }
        }

        menu.addItem(.separator())
        addStatusSection(to: menu, state: state)

        if !state.devices.isEmpty {
            menu.addItem(.separator())
            addDeviceSection(to: menu, state: state)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Allow access from my network",
                                action: #selector(toggleNetwork), keyEquivalent: "")
        toggle.target = self
        toggle.state = state.networkEnabled ? .on : .off
        menu.addItem(toggle)

        addTunnelToggle(to: menu, state: state)

        if state.networkEnabled || state.tunnelActive {
            let rotate = NSMenuItem(title: "Disconnect all devices and reset link",
                                    action: #selector(rotateToken), keyEquivalent: "")
            rotate.target = self
            menu.addItem(rotate)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit screenlink", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addQRSection(to menu: NSMenu, state: MenuBarState) {
        menu.addItem(header("Scan with your phone"))

        if let image = Self.qrCode(for: state.url, size: 220) {
            let item = NSMenuItem()
            item.view = Self.centered(NSImageView(image: image), size: NSSize(width: 260, height: 236))
            menu.addItem(item)
        }

        let url = NSMenuItem(title: "Copy link", action: #selector(copyLink), keyEquivalent: "c")
        url.target = self
        menu.addItem(url)

        // Shown so it can be compared against what the browser reports, which is the only defence
        // against someone impersonating this Mac on the same network.
        if let fingerprint = state.fingerprint {
            let short = fingerprint.split(separator: ":").prefix(8).joined(separator: ":")
            menu.addItem(caption("Certificate \(short)…"))
        }
    }

    private func addLocalOnlySection(to menu: NSMenu) {
        menu.addItem(header("This Mac only"))
        menu.addItem(caption("Turn on network access below to connect a phone."))
    }

    private func addStatusSection(to menu: NSMenu, state: MenuBarState) {
        let screen = NSMenuItem(title: state.capturing
                                    ? "Screen recording allowed"
                                    : "Screen recording needed — click to fix",
                                action: state.capturing ? nil : #selector(openScreenRecording),
                                keyEquivalent: "")
        screen.target = self
        screen.image = Self.dot(state.capturing)
        menu.addItem(screen)

        let input = NSMenuItem(title: state.accessibility
                                   ? "Input control allowed"
                                   : "Input control needed — click to fix",
                               action: state.accessibility ? nil : #selector(openAccessibility),
                               keyEquivalent: "")
        input.target = self
        input.image = Self.dot(state.accessibility)
        menu.addItem(input)

        if state.capturing {
            menu.addItem(caption("Sharing \(state.displayName)"))
        }
    }

    private func addTunnelToggle(to menu: NSMenu, state: MenuBarState) {
        guard state.tunnelInstalled else {
            let missing = NSMenuItem(title: "Reach this Mac from anywhere", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
            menu.addItem(caption("Needs cloudflared: brew install cloudflared"))
            return
        }

        let item = NSMenuItem(title: "Reach this Mac from anywhere",
                              action: #selector(toggleTunnel), keyEquivalent: "")
        item.target = self
        item.state = state.tunnelActive ? .on : .off
        menu.addItem(item)
        if !state.tunnelActive {
            // Said before it is switched on, not after, because afterwards the link already exists.
            menu.addItem(caption("Creates a public web address. Devices still need approval here."))
        }
    }

    private func addDeviceSection(to menu: NSMenu, state: MenuBarState) {
        menu.addItem(header("Approved devices"))

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for device in state.devices {
            let seen = formatter.localizedString(for: device.lastSeenAt, relativeTo: Date())
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")

            // Revoking lives in a submenu so it cannot happen on a stray click, and so the row
            // itself stays readable.
            let submenu = NSMenu()
            submenu.addItem(caption("Last seen \(seen)"))
            submenu.addItem(.separator())
            let revoke = NSMenuItem(title: "Revoke this device",
                                    action: #selector(revokeDevice(_:)), keyEquivalent: "")
            revoke.target = self
            revoke.representedObject = device.id
            submenu.addItem(revoke)
            item.submenu = submenu
            menu.addItem(item)
        }

        let revokeAll = NSMenuItem(title: "Revoke all devices",
                                   action: #selector(revokeAllDevices), keyEquivalent: "")
        revokeAll.target = self
        menu.addItem(revokeAll)
    }

    /// Puts a waiting device in front of the person at the Mac.
    ///
    /// The code is shown on both screens and has to be compared, so that someone else holding the
    /// link cannot be approved by a person who assumes the prompt is about their own phone. Only one
    /// prompt is up at a time, so what is being agreed to is always the request being looked at.
    func presentPairingRequest(_ request: PairingRequest) {
        onMain { [weak self] in
            guard let self else { return }
            waiting.append(request)
            presentNext()
        }
    }

    /// Takes down a prompt whose device is no longer there.
    func withdrawPairingRequest(_ requestId: String) {
        onMain { [weak self] in
            guard let self else { return }
            waiting.removeAll { $0.id == requestId }
            if presenting?.id == requestId {
                // Returns .abort from runModal, which is treated as no decision at all.
                NSApp.abortModal()
            }
        }
    }

    /// Runs on the main thread, including while a modal prompt is up.
    ///
    /// `DispatchQueue.main.async` will not do here. The main queue is drained in the common run loop
    /// modes, and the loop `NSAlert.runModal` spins is not one of them, so a block posted while a
    /// prompt is on screen does not run until that prompt closes — which is precisely when it is
    /// needed, since the whole point is to take the prompt down. Naming the modal mode explicitly is
    /// what gets it delivered.
    private func onMain(_ work: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common, .modalPanel], block: work)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func presentNext() {
        guard presenting == nil, !waiting.isEmpty else { return }
        let request = waiting.removeFirst()
        presenting = request

        let alert = NSAlert()
        alert.messageText = "Pairing code \(request.code)"
        alert.informativeText = """
        \(request.name) at \(request.address) wants to connect.

        Approve only if this same code is showing on that device. An approved device can watch this \
        screen and control it, until you revoke it.
        """
        alert.alertStyle = .warning
        // Deny is the default, so leaning on the return key cannot grant access to a prompt that
        // was not expected.
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Approve")

        // A request nobody answers should lapse on screen too, rather than sitting there long after
        // the device stopped waiting.
        let expiry = Timer.scheduledTimer(withTimeInterval: DeviceStore.requestLifetime,
                                          repeats: false) { [weak self] _ in
            self?.withdrawPairingRequest(request.id)
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        expiry.invalidate()
        presenting = nil

        if response == .abort {
            Log.info("pairing request from \(request.name) withdrawn before a decision")
        } else {
            let approved = response == .alertSecondButtonReturn
            delegate?.menuBarResolvePairing(requestId: request.id, approved: approved)
            Log.info("pairing \(approved ? "approved" : "denied") for \(request.name)")
        }
        presentNext()
    }

    // MARK: - Actions

    @objc private func revokeDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        delegate?.menuBarRevokeDevice(id)
    }

    @objc private func revokeAllDevices() {
        delegate?.menuBarRevokeAllDevices()
    }

    @objc private func toggleNetwork(_ sender: NSMenuItem) {
        delegate?.menuBarSetNetworkAccess(sender.state != .on)
    }

    @objc private func toggleTunnel(_ sender: NSMenuItem) {
        delegate?.menuBarSetTunnel(sender.state != .on)
    }

    @objc private func rotateToken() {
        delegate?.menuBarRotateToken()
    }

    @objc private func copyLink() {
        guard let state = delegate?.menuBarState() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.url, forType: .string)
    }

    @objc private func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Building blocks

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        return item
    }

    private func caption(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private static func dot(_ ok: Bool) -> NSImage? {
        let name = ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = false
        return image
    }

    private static func centered(_ view: NSView, size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = NSRect(x: (size.width - 220) / 2, y: 8, width: 220, height: 220)
        container.addSubview(view)
        return container
    }

    static func qrCode(for string: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // Medium correction survives a phone camera at an angle without inflating the module count,
        // which matters because the URL already carries a 128-bit token.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
