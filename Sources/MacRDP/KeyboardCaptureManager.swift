import Foundation
import AppKit
import SwiftUI
import CoreGraphics

/// Manages keyboard capture mode using CGEvent taps to intercept system shortcuts
/// like Cmd+Tab, Cmd+Space, etc. and forward them to the RDP session.
final class KeyboardCaptureManager: ObservableObject {
    static let shared = KeyboardCaptureManager()
    
    @Published private(set) var isCapturing = false
    @Published private(set) var hasAccessibilityPermission = false
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var session: RdpSession?
    
    private init() {
        checkAccessibilityPermission()
    }
    
    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        
        // Poll for permission change
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.checkAccessibilityPermission()
        }
    }
    
    func startCapturing(session: RdpSession) {
        guard !isCapturing else { return }
        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            return
        }
        
        self.session = session
        
        // Create event tap for keyboard events
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                      (1 << CGEventType.keyUp.rawValue) |
                                      (1 << CGEventType.flagsChanged.rawValue)
        
        // Store self reference for callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<KeyboardCaptureManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        )
        
        guard let eventTap else {
            print("[KeyboardCapture] Failed to create event tap")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            isCapturing = true
            print("[KeyboardCapture] Started capturing keyboard events")
        }
    }
    
    func stopCapturing() {
        guard isCapturing else { return }
        
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
        session = nil
        isCapturing = false
        print("[KeyboardCapture] Stopped capturing keyboard events")
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // If tap is disabled, re-enable it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }
        
        guard let session, case .connected = session.state else {
            return Unmanaged.passRetained(event)
        }
        
        // Check if our window is focused
        guard NSApp.isActive, isRdpWindowFocused() else {
            return Unmanaged.passRetained(event)
        }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        // Determine if this is a system shortcut we should capture
        let isSystemShortcut = shouldCaptureShortcut(keyCode: keyCode, flags: flags)
        
        if isSystemShortcut || type == .keyDown || type == .keyUp || type == .flagsChanged {
            // Forward to RDP session
            if forwardKeyEvent(type: type, keyCode: keyCode, flags: flags) {
                // Consume the event (don't pass to system)
                if isSystemShortcut {
                    return nil
                }
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func isRdpWindowFocused() -> Bool {
        guard let keyWindow = NSApp.keyWindow else { return false }
        // Check if the key window contains our RDP canvas
        return keyWindow.contentView?.subviews.contains(where: { $0 is NSHostingView<AnyView> }) ?? false
            || keyWindow.title.contains("RDP") || keyWindow.title.contains("Mac RDP")
            || NSApp.mainWindow == keyWindow
    }
    
    private func shouldCaptureShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let hasCommand = flags.contains(.maskCommand)
        let hasControl = flags.contains(.maskControl)
        let hasOption = flags.contains(.maskAlternate)
        
        // Capture Cmd+Tab (app switcher)
        if hasCommand && keyCode == 48 { return true }
        
        // Capture Cmd+Space (Spotlight)
        if hasCommand && keyCode == 49 { return true }
        
        // Capture Cmd+` (window switcher within app)
        if hasCommand && keyCode == 50 { return true }
        
        // Capture Ctrl+Arrow keys (Mission Control / Spaces)
        if hasControl && [123, 124, 125, 126].contains(keyCode) { return true }
        
        // Capture Cmd+H (hide app)
        if hasCommand && keyCode == 4 { return true }
        
        // Capture Cmd+M (minimize)
        if hasCommand && keyCode == 46 { return true }
        
        // Capture Cmd+Q (quit) - but allow Cmd+Shift+Q for Windows logout
        if hasCommand && keyCode == 12 && !flags.contains(.maskShift) { return true }
        
        // Capture Option+Tab (some apps use this)
        if hasOption && keyCode == 48 { return true }
        
        // Capture F11/F12 (Mission Control / Dashboard on some Macs)
        if [103, 111].contains(keyCode) && !hasCommand && !hasControl { return true }
        
        return false
    }
    
    private func forwardKeyEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard let session else { return false }
        
        // Map macOS keyCode to Windows scancode
        guard let (scancode, extended) = mapKeyCodeToScancode(keyCode) else {
            return false
        }
        
        switch type {
        case .keyDown:
            var kbdFlags = UInt16(0x4000) // KBD_FLAGS_DOWN
            if extended { kbdFlags |= UInt16(0x0100) } // KBD_FLAGS_EXTENDED
            session.sendKey(flags: kbdFlags, scancode: scancode)
            return true
            
        case .keyUp:
            var kbdFlags = UInt16(0x8000) // KBD_FLAGS_RELEASE
            if extended { kbdFlags |= UInt16(0x0100) } // KBD_FLAGS_EXTENDED
            session.sendKey(flags: kbdFlags, scancode: scancode)
            return true
            
        case .flagsChanged:
            // Handle modifier key changes
            handleModifierChange(keyCode: keyCode, flags: flags)
            return true
            
        default:
            return false
        }
    }
    
    private var previousModifiers: CGEventFlags = []
    
    private func handleModifierChange(keyCode: UInt16, flags: CGEventFlags) {
        guard let session else { return }
        
        let modifierMappings: [(CGEventFlags, UInt16, Bool)] = [
            (.maskShift, 0x2A, false),      // left shift
            (.maskControl, 0x1D, false),    // left control
            (.maskAlternate, 0x38, false),  // left option/alt
            (.maskCommand, 0x5B, true),     // left command -> Windows key
        ]
        
        for (flag, scancode, extended) in modifierMappings {
            let wasDown = previousModifiers.contains(flag)
            let isDown = flags.contains(flag)
            
            if isDown && !wasDown {
                var kbdFlags = UInt16(0x4000) // KBD_FLAGS_DOWN
                if extended { kbdFlags |= UInt16(0x0100) }
                session.sendKey(flags: kbdFlags, scancode: scancode)
            } else if !isDown && wasDown {
                var kbdFlags = UInt16(0x8000) // KBD_FLAGS_RELEASE
                if extended { kbdFlags |= UInt16(0x0100) }
                session.sendKey(flags: kbdFlags, scancode: scancode)
            }
        }
        
        previousModifiers = flags
    }
    
    private func mapKeyCodeToScancode(_ keyCode: UInt16) -> (UInt16, Bool)? {
        // Same mapping as RdpCanvasView
        let specialKeys: [UInt16: (UInt16, Bool)] = [
            36: (0x1C, false), // return
            48: (0x0F, false), // tab
            49: (0x39, false), // space
            50: (0x29, false), // backtick
            51: (0x0E, false), // delete
            53: (0x01, false), // escape
            123: (0x4B, true), // left arrow
            124: (0x4D, true), // right arrow
            125: (0x50, true), // down arrow
            126: (0x48, true), // up arrow
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
        ]
        
        if let mapped = specialKeys[keyCode] {
            return mapped
        }
        
        // Letter keys
        let letterKeys: [UInt16: (UInt16, Bool)] = [
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
        ]
        
        return letterKeys[keyCode]
    }
}
