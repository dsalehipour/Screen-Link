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
}

protocol MenuBarDelegate: AnyObject {
    func menuBarState() -> MenuBarState
    func menuBarSetNetworkAccess(_ enabled: Bool)
    func menuBarRotateToken()
}

/// The status-bar surface.
///
/// Everything a person needs to get their phone connected lives here, because the alternative is a
/// terminal, and a product that requires a terminal is not a product.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var delegate: MenuBarDelegate?
    private var refreshTimer: Timer?

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

        if state.networkEnabled {
            addQRSection(to: menu, state: state)
        } else {
            addLocalOnlySection(to: menu)
        }

        menu.addItem(.separator())
        addStatusSection(to: menu, state: state)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Allow access from my network",
                                action: #selector(toggleNetwork), keyEquivalent: "")
        toggle.target = self
        toggle.state = state.networkEnabled ? .on : .off
        menu.addItem(toggle)

        if state.networkEnabled {
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

    // MARK: - Actions

    @objc private func toggleNetwork(_ sender: NSMenuItem) {
        delegate?.menuBarSetNetworkAccess(sender.state != .on)
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
