# Mac RDP

A native macOS RDP client built with SwiftUI and FreeRDP. Connect to Windows hosts with a clean, modern interface.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Connection Management**: Save connections, import .rdp files, secure Keychain password storage
- **Full Input Support**: Mouse, keyboard, scroll wheel, modifier keys, keyboard capture mode
- **Clipboard Sharing**: Bidirectional copy/paste between Mac and Windows
- **Drive Redirection**: Share local folders with remote Windows session
- **Certificate Validation**: View certificate details, accept once or always trust
- **Modern UI**: Dark mode, collapsible sidebar, fullscreen support, connection health indicator
- **Resolution Presets**: Quick-select 720p, 1080p, 1440p
- **Session Management**: Graceful disconnect handling, reconnect support

## Screenshots

Screenshots coming soon.

## Requirements

- macOS 14+ (Sonoma)
- Xcode 15+ / Swift 5.9
- FreeRDP 3.x

## Quick Start

### Basic Installation (Homebrew)

```bash
# Install dependencies
brew install freerdp pkg-config

# Clone and run
git clone https://github.com/kxxil01/macrdp.git
cd macrdp
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"
swift run MacRDP
```

### Advanced Installation (Full Features)

For clipboard sharing and drive redirection, build FreeRDP from source:

```bash
# Remove Homebrew version
brew uninstall freerdp

# Build FreeRDP with dynamic channels
git clone https://github.com/FreeRDP/FreeRDP.git /tmp/freerdp-build
cd /tmp/freerdp-build && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/opt/homebrew -DBUILTIN_CHANNELS=OFF
make -j$(sysctl -n hw.ncpu) && sudo make install

# Run Mac RDP
cd /path/to/macrdp
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig"
swift run MacRDP
```

## Keyboard Shortcuts

### Mac App Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+S` | Toggle sidebar |
| `Cmd+O` | Import .rdp file |
| `Cmd+Return` | Connect |
| `Cmd+Shift+D` | Disconnect |
| `Cmd+Ctrl+F` | Toggle fullscreen |
| `Esc` | Exit fullscreen |

### In RDP Session (Windows)

| Shortcut | Action |
|----------|--------|
| `Ctrl+C` | Copy |
| `Ctrl+V` | Paste |
| `Ctrl+X` | Cut |
| `Ctrl+A` | Select All |
| `Ctrl+Z` | Undo |

## Architecture

```text
Sources/
├── CFREERDP/           # System library target (pkg-config)
├── CRDP/               # C shim wrapping FreeRDP
│   ├── include/        # Public headers
│   ├── crdp.c          # FreeRDP wrapper, channel handlers
│   └── clipboard_mac.m # macOS clipboard bridge
└── MacRDP/             # SwiftUI application
    ├── MacRDPApp.swift
    ├── ContentView.swift
    ├── RdpCanvasView.swift
    ├── RdpSession.swift
    └── ConnectionStore.swift
```

## Roadmap

### Completed

- [x] Connection history/favorites with Keychain password storage
- [x] Fullscreen mode with auto-hiding sidebar
- [x] Mouse wheel scrolling (vertical + horizontal)
- [x] Import .rdp files
- [x] Drive redirection (share local folders)
- [x] Clipboard sharing (bidirectional)
- [x] Certificate validation UI
- [x] Connection health indicator (RTT display)
- [x] Export/Import connections
- [x] Session disconnect handling with reconnect
- [x] Keyboard capture mode (Cmd+Tab, Cmd+Space, etc.)

### Planned

- [ ] Custom resolution input
- [ ] Auto-reconnect on connection drop
- [ ] Audio redirection
- [ ] Multi-monitor support

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [FreeRDP](https://www.freerdp.com/) - The RDP protocol implementation
- Built with SwiftUI and AppKit
