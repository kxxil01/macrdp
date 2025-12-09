import SwiftUI
import AppKit
import CRDP

struct RdpCanvasView: NSViewRepresentable {
    @ObservedObject var session: RdpSession

    func makeNSView(context: Context) -> Canvas {
        let view = Canvas()
        view.session = session
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1.0).cgColor
        return view
    }

    func updateNSView(_ nsView: Canvas, context: Context) {
        nsView.session = session
        nsView.image = session.frame
    }
}

final class Canvas: NSView {
    weak var session: RdpSession?
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let image else { return }
        let bounds = self.bounds
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(x: (bounds.width - drawSize.width) / 2.0,
                              y: (bounds.height - drawSize.height) / 2.0,
                              width: drawSize.width,
                              height: drawSize.height)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        // Fix inverted image: save state, flip context, draw, restore
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1.0, y: -1.0)
        
        let flippedRect = NSRect(x: drawRect.origin.x,
                                  y: bounds.height - drawRect.origin.y - drawRect.height,
                                  width: drawRect.width,
                                  height: drawRect.height)
        
        ctx.interpolationQuality = .high
        ctx.draw(image, in: flippedRect)
        ctx.restoreGState()
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        sendPointer(button: .left, isDown: true, isMove: false, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(button: .left, isDown: false, isMove: false, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendPointer(button: .right, isDown: true, isMove: false, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointer(button: .right, isDown: false, isMove: false, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendPointer(button: .middle, isDown: true, isMove: false, event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointer(button: .middle, isDown: false, isMove: false, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(button: .left, isDown: true, isMove: true, event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(button: .right, isDown: true, isMove: true, event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(button: .middle, isDown: true, isMove: true, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(button: nil, isDown: false, isMove: true, event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        sendScroll(event: event)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        sendKey(event: event, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event: event, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        sendModifierKey(event: event)
    }

}

// MARK: - Input helpers

private extension Canvas {
    enum MouseButton {
        case left, right, middle
    }

    func sendPointer(button: MouseButton?, isDown: Bool, isMove: Bool, event: NSEvent) {
        guard let session else { return }
        let (x, y) = translateToRemote(event: event)
        var flags: UInt16 = UInt16(PTR_FLAGS_MOVE)

        if let button {
            switch button {
            case .left:
                flags = UInt16(PTR_FLAGS_BUTTON1)
            case .right:
                flags = UInt16(PTR_FLAGS_BUTTON2)
            case .middle:
                flags = UInt16(PTR_FLAGS_BUTTON3)
            }
            if isDown {
                flags |= UInt16(PTR_FLAGS_DOWN)
            }
            if isMove {
                flags |= UInt16(PTR_FLAGS_MOVE)
            }
        }

        session.sendPointer(flags: flags, x: x, y: y)
    }

    func sendScroll(event: NSEvent) {
        guard let session else { return }
        let (x, y) = translateToRemote(event: event)
        
        // Vertical scroll
        if event.scrollingDeltaY != 0 {
            var flags = UInt16(PTR_FLAGS_WHEEL)
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
            let rotation = Int16(max(-0x00FF, min(0x00FF, delta * 10)))
            
            if rotation < 0 {
                flags |= UInt16(PTR_FLAGS_WHEEL_NEGATIVE)
                flags |= UInt16((-rotation) & 0x01FF)
            } else {
                flags |= UInt16(rotation & 0x01FF)
            }
            session.sendPointer(flags: flags, x: x, y: y)
        }
        
        // Horizontal scroll
        if event.scrollingDeltaX != 0 {
            var flags = UInt16(PTR_FLAGS_HWHEEL)
            let delta = event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 10)
            let rotation = Int16(max(-0x00FF, min(0x00FF, delta * 10)))
            
            if rotation < 0 {
                flags |= UInt16(PTR_FLAGS_WHEEL_NEGATIVE)
                flags |= UInt16((-rotation) & 0x01FF)
            } else {
                flags |= UInt16(rotation & 0x01FF)
            }
            session.sendPointer(flags: flags, x: x, y: y)
        }
    }

    func translateToRemote(event: NSEvent) -> (UInt16, UInt16) {
        let loc = convert(event.locationInWindow, from: nil)
        let bounds = self.bounds
        let remote = session?.remoteSize ?? .zero
        guard remote.width > 0, remote.height > 0, bounds.width > 0, bounds.height > 0 else {
            return (0, 0)
        }

        let scale = min(bounds.width / remote.width, bounds.height / remote.height)
        let drawWidth = remote.width * scale
        let drawHeight = remote.height * scale
        let offsetX = (bounds.width - drawWidth) / 2.0
        let offsetY = (bounds.height - drawHeight) / 2.0

        let x = max(0, min(remote.width - 1, (loc.x - offsetX) / scale))
        let y = max(0, min(remote.height - 1, (loc.y - offsetY) / scale))

        return (UInt16(x), UInt16(y))
    }

    func sendKey(event: NSEvent, isDown: Bool) {
        guard let (scan, extended) = mapScancode(event: event), let session else { return }
        var flags: UInt16 = isDown ? UInt16(KBD_FLAGS_DOWN) : UInt16(KBD_FLAGS_RELEASE)
        if extended {
            flags |= UInt16(KBD_FLAGS_EXTENDED)
        }
        session.sendKey(flags: flags, scancode: scan)
    }

    func mapScancode(event: NSEvent) -> (UInt16, Bool)? {
        // First try keyCode lookup (more reliable for special keys and shifted characters)
        if let mapped = specialKeycodeToScancode[event.keyCode] {
            return mapped
        }
        
        // Then try keyCode to character mapping for number/symbol keys
        if let mapped = keycodeToScancode[event.keyCode] {
            return mapped
        }

        // Fall back to character-based lookup
        if let char = event.charactersIgnoringModifiers?.lowercased().first {
            if let mapped = charToScancode[char] {
                return mapped
            }
        }

        return nil
    }

    // Track previous modifier state to detect key up/down
    private static var previousModifiers: NSEvent.ModifierFlags = []

    func sendModifierKey(event: NSEvent) {
        guard let session else { return }
        let current = event.modifierFlags
        let previous = Canvas.previousModifiers
        Canvas.previousModifiers = current

        // Caps Lock - special handling: macOS toggles on key down only
        // We need to send both down and up to Windows for it to toggle
        if event.keyCode == 57 { // Caps Lock key
            let scancode: UInt16 = 0x3A
            // Send key down
            session.sendKey(flags: UInt16(KBD_FLAGS_DOWN), scancode: scancode)
            // Send key up immediately after
            session.sendKey(flags: UInt16(KBD_FLAGS_RELEASE), scancode: scancode)
            return
        }

        // Handle other modifier keys: (flag, scancode, extended)
        let modifierMappings: [(NSEvent.ModifierFlags, UInt16, Bool)] = [
            (.shift, 0x2A, false),      // left shift
            (.control, 0x1D, false),    // left control
            (.option, 0x38, false),     // left option/alt
            (.command, 0x5B, true),     // left command -> Windows key
        ]

        for (flag, scancode, extended) in modifierMappings {
            let wasDown = previous.contains(flag)
            let isDown = current.contains(flag)

            if isDown && !wasDown {
                // Key pressed
                var flags = UInt16(KBD_FLAGS_DOWN)
                if extended { flags |= UInt16(KBD_FLAGS_EXTENDED) }
                session.sendKey(flags: flags, scancode: scancode)
            } else if !isDown && wasDown {
                // Key released
                var flags = UInt16(KBD_FLAGS_RELEASE)
                if extended { flags |= UInt16(KBD_FLAGS_EXTENDED) }
                session.sendKey(flags: flags, scancode: scancode)
            }
        }
    }
}

// macOS keyCode -> (scancode, extended) for all standard keys
// This is more reliable than character-based lookup for shifted keys
private let keycodeToScancode: [UInt16: (UInt16, Bool)] = [
    // Number row (keyCodes 18-29 for 1-0, then symbols)
    18: (0x02, false), // 1 / !
    19: (0x03, false), // 2 / @
    20: (0x04, false), // 3 / #
    21: (0x05, false), // 4 / $
    23: (0x06, false), // 5 / %
    22: (0x07, false), // 6 / ^
    26: (0x08, false), // 7 / &
    28: (0x09, false), // 8 / *
    25: (0x0A, false), // 9 / (
    29: (0x0B, false), // 0 / )
    27: (0x0C, false), // - / _
    24: (0x0D, false), // = / +
    // Letter keys
    0: (0x1E, false),  // a
    11: (0x30, false), // b
    8: (0x2E, false),  // c
    2: (0x20, false),  // d
    14: (0x12, false), // e
    3: (0x21, false),  // f
    5: (0x22, false),  // g
    4: (0x23, false),  // h
    34: (0x17, false), // i
    38: (0x24, false), // j
    40: (0x25, false), // k
    37: (0x26, false), // l
    46: (0x32, false), // m
    45: (0x31, false), // n
    31: (0x18, false), // o
    35: (0x19, false), // p
    12: (0x10, false), // q
    15: (0x13, false), // r
    1: (0x1F, false),  // s
    17: (0x14, false), // t
    32: (0x16, false), // u
    9: (0x2F, false),  // v
    13: (0x11, false), // w
    7: (0x2D, false),  // x
    16: (0x15, false), // y
    6: (0x2C, false),  // z
    // Symbol keys
    33: (0x1A, false), // [ / {
    30: (0x1B, false), // ] / }
    41: (0x27, false), // ; / :
    39: (0x28, false), // ' / "
    42: (0x2B, false), // \ / |
    43: (0x33, false), // , / <
    47: (0x34, false), // . / >
    44: (0x35, false), // / / ?
    50: (0x29, false), // ` / ~
]

private let charToScancode: [Character: (UInt16, Bool)] = [
    "a": (0x1E, false), "b": (0x30, false), "c": (0x2E, false), "d": (0x20, false),
    "e": (0x12, false), "f": (0x21, false), "g": (0x22, false), "h": (0x23, false),
    "i": (0x17, false), "j": (0x24, false), "k": (0x25, false), "l": (0x26, false),
    "m": (0x32, false), "n": (0x31, false), "o": (0x18, false), "p": (0x19, false),
    "q": (0x10, false), "r": (0x13, false), "s": (0x1F, false), "t": (0x14, false),
    "u": (0x16, false), "v": (0x2F, false), "w": (0x11, false), "x": (0x2D, false),
    "y": (0x15, false), "z": (0x2C, false),
    "1": (0x02, false), "2": (0x03, false), "3": (0x04, false), "4": (0x05, false),
    "5": (0x06, false), "6": (0x07, false), "7": (0x08, false), "8": (0x09, false),
    "9": (0x0A, false), "0": (0x0B, false),
    "-": (0x0C, false), "=": (0x0D, false), "[": (0x1A, false), "]": (0x1B, false),
    ";": (0x27, false), "'": (0x28, false), "\\": (0x2B, false), ",": (0x33, false),
    ".": (0x34, false), "/": (0x35, false), "`": (0x29, false), " ": (0x39, false)
]

// keyCode -> (scancode, extended)
private let specialKeycodeToScancode: [UInt16: (UInt16, Bool)] = [
    36: (0x1C, false), // return
    52: (0x1C, true),  // keypad enter
    48: (0x0F, false), // tab
    53: (0x01, false), // escape
    51: (0x0E, false), // delete (backspace)
    117: (0x53, true), // forward delete
    49: (0x39, false), // space
    123: (0x4B, true), // left arrow
    124: (0x4D, true), // right arrow
    125: (0x50, true), // down arrow
    126: (0x48, true), // up arrow
    115: (0x47, true), // home
    119: (0x4F, true), // end
    116: (0x49, true), // page up
    121: (0x51, true), // page down
    122: (0x3B, false), // F1
    120: (0x3C, false), // F2
    99: (0x3D, false),  // F3
    118: (0x3E, false), // F4
    96: (0x3F, false),  // F5
    97: (0x40, false),  // F6
    98: (0x41, false),  // F7
    100: (0x42, false), // F8
    101: (0x43, false), // F9
    109: (0x44, false), // F10
    103: (0x57, false), // F11
    111: (0x58, false), // F12
    56: (0x2A, false),  // left shift
    60: (0x36, false),  // right shift
    59: (0x1D, false),  // left control
    62: (0x1D, true),   // right control
    58: (0x38, false),  // left option (alt)
    61: (0x38, true),   // right option (alt)
    55: (0x5B, true),   // left command -> left Windows
    54: (0x5C, true),   // right command -> right Windows
    57: (0x3A, false)   // caps lock
]
