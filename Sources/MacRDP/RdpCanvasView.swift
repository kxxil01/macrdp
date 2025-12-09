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
        NSColor.windowBackgroundColor.setFill()
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

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        sendKey(event: event, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event: event, isDown: false)
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
        if let char = event.charactersIgnoringModifiers?.lowercased().first {
            if let mapped = charToScancode[char] {
                return mapped
            }
        }

        if let mapped = specialKeycodeToScancode[event.keyCode] {
            return mapped
        }

        return nil
    }
}

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
