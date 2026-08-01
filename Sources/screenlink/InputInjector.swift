import CoreGraphics
import Foundation

final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()

    /// Follows the captured display so injected coordinates stay on whatever the viewer is watching.
    private var _displayID: CGDirectDisplayID
    var displayID: CGDirectDisplayID {
        get { lock.lock(); defer { lock.unlock() }; return _displayID }
        set { lock.lock(); _displayID = newValue; lock.unlock() }
    }

    private var heldButtons: Set<String> = []
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint: CGPoint = .zero
    private var clickCount: Int64 = 1

    init(displayID: CGDirectDisplayID) {
        self._displayID = displayID
    }

    /// Normalized [0,1] to the global top-left-origin point space that CGEvent expects.
    /// CGDisplayBounds is already in points and already offset for this display's position in
    /// the desktop arrangement, so backing scale never enters the calculation.
    private func point(_ nx: Double, _ ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: bounds.origin.x + min(max(nx, 0), 1) * bounds.width,
            y: bounds.origin.y + min(max(ny, 0), 1) * bounds.height)
    }

    func handle(_ command: InputCommand) {
        switch command.type {
        case .mouse:
            guard let action = command.action, let x = command.x, let y = command.y else { return }
            mouse(action: action, at: point(x, y), button: command.button ?? "left", flags: command.modifiers)
        case .scroll:
            guard let x = command.x, let y = command.y else { return }
            scroll(at: point(x, y), dx: command.dx ?? 0, dy: command.dy ?? 0, flags: command.modifiers)
        case .key:
            guard let action = command.action, let code = command.code else { return }
            key(down: action == "down", code: code, flags: command.modifiers)
        case .text:
            guard let text = command.text else { return }
            type(text)
        case .auth, .keyframe, .display, .quality:
            break
        }
    }

    private func mouse(action: String, at p: CGPoint, button: String, flags: CGEventFlags) {
        lock.lock()
        let type: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case "right": cgButton = .right
        case "middle": cgButton = .center
        default: cgButton = .left
        }

        switch action {
        case "down":
            heldButtons.insert(button)
            // Rapid clicks in the same spot must carry an increasing click count or the target
            // app never sees a double-click.
            let now = Date().timeIntervalSince1970
            let nearby = abs(p.x - lastClickPoint.x) < 5 && abs(p.y - lastClickPoint.y) < 5
            clickCount = (now - lastClickTime < 0.4 && nearby) ? clickCount + 1 : 1
            lastClickTime = now
            lastClickPoint = p
            type = cgButton == .right ? .rightMouseDown : (cgButton == .center ? .otherMouseDown : .leftMouseDown)
        case "up":
            heldButtons.remove(button)
            type = cgButton == .right ? .rightMouseUp : (cgButton == .center ? .otherMouseUp : .leftMouseUp)
        default:
            // A move while a button is held must be a drag event, otherwise selection and
            // window dragging silently do nothing.
            if heldButtons.contains("left") {
                type = .leftMouseDragged
            } else if heldButtons.contains("right") {
                type = .rightMouseDragged
            } else if heldButtons.contains("middle") {
                type = .otherMouseDragged
            } else {
                type = .mouseMoved
            }
        }
        let count = clickCount
        lock.unlock()

        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton)
        else { return }
        event.flags = flags
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: count)
        }
        event.post(tap: .cghidEventTap)
    }

    private func scroll(at p: CGPoint, dx: Double, dy: Double, flags: CGEventFlags) {
        // Scroll events land on whatever is under the cursor, so position it first.
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        // Browser deltaY is positive scrolling down; CGEvent wheel1 is positive scrolling up.
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(-dy)),
            wheel2: Int32(clamping: Int(-dx)),
            wheel3: 0)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func key(down: Bool, code: String, flags: CGEventFlags) {
        guard let vk = KeyMap.virtualKey(for: code) else {
            Log.warn("unmapped key code: \(code)")
            return
        }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Injects characters as Unicode rather than synthesizing keycodes, which works for any
    /// character and any keyboard layout without a reverse layout lookup.
    private func type(_ text: String) {
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
