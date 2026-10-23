import CoreGraphics

/// Synthesizes mouse and keyboard input with CoreGraphics events.
/// Requires the Accessibility permission (System Settings → Privacy & Security → Accessibility).
final class InputController {
    private var displays: [CGRect] = []
    private var dragging = false               // left button held (tap-and-drag)
    private var overviewKey: CGKeyCode?        // key that opened Mission Control / App Exposé

    private enum Key {
        static let control: CGKeyCode = 59
        static let left: CGKeyCode = 123, right: CGKeyCode = 124, down: CGKeyCode = 125, up: CGKeyCode = 126
    }

    init() { refreshDisplays() }

    /// Cache the bounds of all active displays (global coordinates, points).
    func refreshDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        if displays.isEmpty { displays = [CGDisplayBounds(CGMainDisplayID())] }
    }

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    // MARK: Mouse

    func move(dx: Double, dy: Double) {
        let current = cursor
        var p = CGPoint(x: current.x + dx, y: current.y + dy)
        // Moving onto another display is fine; off the desktop clamps to the current display.
        if !displays.contains(where: { $0.contains(p) }) {
            let b = displays.first(where: { $0.contains(current) }) ?? displays[0]
            p.x = min(max(p.x, b.minX), b.maxX - 1)
            p.y = min(max(p.y, b.minY), b.maxY - 1)
        }
        // While the button is held, apps expect "dragged" events instead of "moved".
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        post(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left))
    }

    /// Mouse events go out with no modifier flags. Otherwise they can pick up a Control
    /// left "down" by a swipe shortcut, and macOS turns Ctrl + left click into a right click.
    private func post(_ event: CGEvent?) {
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }

    /// Press + release. count = 2 marks the second click of a double click,
    /// which is how macOS recognizes double clicks from synthetic events.
    func click(right: Bool, count: Int) {
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
            ? (.rightMouseDown, .rightMouseUp, .right)
            : (.leftMouseDown, .leftMouseUp, .left)
        let p = cursor
        for type in [down, up] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            post(event)
        }
        overviewKey = nil  // a click picks a window in Mission Control, which closes it
    }

    /// Press or release the left button (start / end a drag).
    func hold(_ down: Bool) {
        guard down != dragging else { return }
        dragging = down
        post(CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp,
                     mouseCursorPosition: cursor, mouseButton: .left))
    }

    func scroll(dx: Int32, dy: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: Three-finger swipes

    /// Real trackpad gestures can't be synthesized with public APIs, so we send the default
    /// Mission Control shortcuts (System Settings → Keyboard → Keyboard Shortcuts → Mission Control):
    ///   left / right → Ctrl+→ / Ctrl+←  (next / previous desktop; content follows the fingers)
    ///   up           → Ctrl+↑           (Mission Control)
    ///   down         → Ctrl+↓           (App Exposé)
    /// Like on a trackpad, swiping the other way closes an open overview.
    func swipe(_ direction: String) {
        switch direction {
        case "l": press(Key.right)
        case "r": press(Key.left)
        case "u", "d":
            if let key = overviewKey {
                press(key)  // the shortcut toggles, so this closes it
                overviewKey = nil
            } else {
                let key = direction == "u" ? Key.up : Key.down
                press(key)
                overviewKey = key
            }
        default: break
        }
    }

    private func press(_ key: CGKeyCode) {
        // Arrow keys carry the Fn flag; the system shortcuts are registered with it.
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = [.maskControl, .maskSecondaryFn]
            event?.post(tap: .cghidEventTap)
        }
        // Release Control explicitly so the system doesn't keep it as held.
        let controlUp = CGEvent(keyboardEventSource: nil, virtualKey: Key.control, keyDown: false)
        controlUp?.flags = []
        controlUp?.post(tap: .cghidEventTap)
    }
}
