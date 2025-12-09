# Mac RDP - Agent Guidelines

## Project Overview

Mac RDP is a native macOS RDP client built with SwiftUI and FreeRDP. It provides a minimal, elegant interface for connecting to Windows hosts over RDP/TLS.

## Architecture

```text
Sources/
├── CFREERDP/          # System library target for FreeRDP via pkg-config
├── CRDP/              # C shim wrapping FreeRDP in Swift-friendly API
│   ├── include/       # Public headers (crdp.h)
│   └── crdp.c         # Implementation
└── MacRDP/            # SwiftUI application
    ├── MacRDPApp.swift      # App entry point, window configuration, menu commands
    ├── ContentView.swift    # Main UI with sidebar layout, forms, floating controls
    ├── RdpCanvasView.swift  # NSViewRepresentable for frame rendering, input handling
    ├── RdpSession.swift     # RDP session state management, connection lifecycle
    └── ConnectionStore.swift # Persistent storage for saved connections
```

## Current Features

### Connection Management

- **Recent connections**: Auto-saved with host, credentials, and settings
- **Password persistence**: Stored with show/hide toggle (eye icon)
- **Import .rdp files**: Standard Microsoft RDP file format support
- **Connection validation**: Required field checks before connecting

### Display & Input

- **Mouse support**: Click, drag, right-click, middle-click
- **Scroll support**: Vertical and horizontal (trackpad/mouse wheel)
- **Keyboard mapping**: Full keyboard with special keys (F1-F12, arrows, modifiers)
- **Resolution presets**: 720p, 1080p, 1440p quick-select buttons

### UI/UX

- **Collapsible sidebar**: Auto-hides when connected, hover to reveal in fullscreen
- **Floating toolbar**: Resolution display, fullscreen toggle, disconnect button
- **Connection states**: Visual feedback for disconnected/connecting/connected/failed
- **Dark mode**: Full system appearance support

## UI/UX Design Principles

### Layout

- **Sidebar pattern**: Connection settings in collapsible left sidebar (300px)
- **Canvas area**: Full-width RDP frame display with grid pattern when empty
- **Floating controls**: Sidebar toggle, status indicator, toolbar overlay on canvas

### Visual Hierarchy

- **Form sections**: Grouped by function (Connection, Credentials, Display, Options)
- **Section headers**: Uppercase labels with SF Symbols icons
- **Status bar**: Bottom of sidebar with connection state and resolution

### Interaction Patterns

- **Hover states**: Subtle scale animations on buttons (1.02x)
- **Status colors**: Gray (disconnected), Orange (connecting), Green (connected), Red (failed)
- **Auto-collapse**: Sidebar hides on connect, shows on disconnect
- **Smooth animations**: Spring animations for all transitions

### Accessibility

- Uses system colors (`NSColor.windowBackgroundColor`, etc.) for dark mode
- Proper contrast with `.secondary` and `.tertiary` text styles
- Help tooltips on all icon-only buttons

## Code Style

### SwiftUI Views

- Extract complex views into computed properties (`private var sidebar: some View`)
- Use `@ViewBuilder` for reusable components (`FormSection`, `FormField`)
- Prefer `.frame(maxWidth: .infinity)` over fixed widths

### State Management

- `@StateObject` for session (owned by view)
- `@ObservedObject` for shared stores (ConnectionStore.shared)
- `@State` for local UI state (form fields, hover states)
- `@Published` in observable classes for reactive updates

### Naming Conventions

- Views: PascalCase (`ContentView`, `FormSection`)
- Properties: camelCase (`showSidebar`, `isHoveringConnect`)
- Constants: camelCase in context (`sidebarWidth`)

## Dependencies

- **FreeRDP 3.x**: RDP protocol implementation (via Homebrew)
- **pkg-config**: Build-time dependency resolution
- **macOS 13+**: Minimum deployment target

## Build & Run

```bash
# Install FreeRDP via Homebrew (basic features)
brew install freerdp

# Ensure pkg-config can find freerdp3
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"

# Build and run
swift run MacRDP
```

### Advanced Features (Drive/Clipboard Redirection)

Homebrew's FreeRDP builds channels statically, which prevents dynamic loading of rdpdr (drive) and cliprdr (clipboard) plugins. To enable these features, build FreeRDP from source:

```bash
brew uninstall freerdp
git clone https://github.com/FreeRDP/FreeRDP.git /tmp/freerdp-build
cd /tmp/freerdp-build && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/opt/homebrew -DBUILTIN_CHANNELS=OFF
make -j$(sysctl -n hw.ncpu) && sudo make install
```

## Key Files

| File | Purpose |
|------|---------|
| `ContentView.swift` | Main layout, sidebar, forms, floating controls, keyboard shortcuts |
| `MacRDPApp.swift` | Window configuration, menu commands |
| `RdpCanvasView.swift` | Frame rendering, mouse/keyboard/scroll input |
| `RdpSession.swift` | Connection state, frame handling, C shim bridge |
| `ConnectionStore.swift` | UserDefaults persistence for saved connections |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+S` | Toggle sidebar |
| `Cmd+O` | Import .rdp file |
| `Cmd+Return` | Connect |
| `Cmd+Shift+D` | Disconnect |
| `Cmd+Ctrl+F` | Toggle fullscreen |
| `Esc` | Exit fullscreen |

## Roadmap

### Done

- [x] Connection history/favorites persistence
- [x] Password persistence with show/hide toggle
- [x] Keyboard shortcut for sidebar toggle (Cmd+Shift+S)
- [x] Full-screen mode with auto-hiding sidebar
- [x] Mouse wheel scrolling (vertical + horizontal)
- [x] Import .rdp file support
- [x] Connection validation with error alerts
- [x] Auto-collapse sidebar on connect
- [x] Floating toolbar with resolution display
- [x] Custom connecting animation
- [x] Caps Lock and modifier key sync
- [x] Drive redirection UI (share local folder with remote Windows)
  - **Note**: Requires FreeRDP built with `BUILTIN_CHANNELS=OFF`. Homebrew's FreeRDP has static channels which prevents dynamic loading of rdpdr plugin.
- [x] Connection timeout with retry option

### Planned

#### High Priority (Functionality)

- [ ] **Clipboard sharing**: Text copy/paste between local and remote (same FreeRDP limitation as drive redirection)
- [ ] **Secure password storage**: Use macOS Keychain instead of UserDefaults
- [ ] **Certificate validation UI**: Show cert details, allow trust decisions

#### Medium Priority (UX)

- [ ] **Quick connect**: Command palette (Cmd+K) for fast server switching
- [ ] **Connection groups/folders**: Organize saved connections
- [ ] **Export connections**: Backup/restore saved connections
- [ ] **Touch Bar support**: Quick actions for MacBook Pro
- [ ] **Dock menu**: Recent connections in right-click dock menu

#### Low Priority (Advanced)

- [ ] **Multi-monitor support**: Span across multiple displays
- [ ] **Audio redirection**: Play remote audio locally
- [ ] **Printer redirection**: Print to local printers
- [ ] **RemoteApp mode**: Run individual apps instead of full desktop
- [ ] **Gateway support**: RD Gateway for secure external access

#### Code Quality

- [ ] **Unit tests**: Test ConnectionStore, RdpSession state machine
- [ ] **UI tests**: Test connection flow, sidebar behavior
- [ ] **Error handling**: More granular error types and recovery options
- [ ] **Logging**: Structured logging for debugging connections
