# mac-rdp (Swift + FreeRDP)

A minimal native macOS RDP client built with SwiftUI on top of FreeRDP. It connects to a Windows host over RDP/TLS with keyboard/mouse input and a software-rendered framebuffer.

## Requirements

- macOS 13+ (deployment target)
- Xcode 15+ / Swift 5.9 toolchain
- Homebrew `freerdp` 3.x (and `pkg-config`): `brew install freerdp pkg-config`

## Running

```bash
swift run MacRDP
```

If you are prompted that `pkg-config` cannot find `freerdp3`, ensure Homebrew's pkgconfig path is visible:

```bash
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"
swift run MacRDP
```

The package also adds fallback include/lib search paths for Homebrew in `/opt/homebrew` (Apple Silicon) and `/usr/local` (Intel), but `pkg-config` is still recommended so SPM can find `freerdp3`.

### macOS SDK notes

Homebrew builds `freerdp3` for the latest macOS (often 15). When targeting macOS 13 you may see linker warnings about newer-built dylibs. Options:

- Ignore the warnings (works in practice).
- Rebuild FreeRDP against your target SDK; or if you exclusively target newer macOS, bump `platforms` in `Package.swift` once your SwiftPM toolchain supports `.macOS(.v15)`.

## Features

- Host/port, username/password, optional domain
- NLA toggle, optional GFX pipeline toggle
- Software GDI rendering; frames presented via CGImage
- Basic mouse (left/right/middle, drag) and keyboard (US layout) input

## Limitations

- Accepts all server certificates (no prompt/validation)
- Keyboard mapping is minimal (US layout; common keys only); no IME
- No clipboard, audio, multi-monitor, wheel/gesture support, or gateway support

## Notes

The C shim wraps FreeRDP (`Sources/CRDP`) and emits BGRA frames to Swift. The SwiftUI shell (`Sources/MacRDP`) handles UI, image presentation, and input translation. This is an MVP; expect to harden security, input mapping, and channel support before shipping.
