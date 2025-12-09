# Mac RDP - Agent Guidelines

## Project Overview

Mac RDP is a native macOS RDP client built with SwiftUI and FreeRDP. It provides a minimal, elegant interface for connecting to Windows hosts over RDP/TLS.

## Architecture

```text
Sources/
├── CFREERDP/          # System library target for FreeRDP via pkg-config
├── CRDP/              # C shim wrapping FreeRDP in Swift-friendly API
│   ├── include/       # Public headers
│   └── crdp.c         # Implementation
└── MacRDP/            # SwiftUI application
    ├── MacRDPApp.swift      # App entry point, window configuration
    ├── ContentView.swift    # Main UI with sidebar layout
    ├── RdpCanvasView.swift  # NSViewRepresentable for frame rendering
    └── RdpSession.swift     # RDP session state management
```

## UI/UX Design Principles

### Layout

- **Sidebar pattern**: Connection settings in collapsible left sidebar (280px)
- **Canvas area**: Full-width RDP frame display with grid pattern when empty
- **Floating controls**: Sidebar toggle and status indicator overlay on canvas

### Visual Hierarchy

- **Form sections**: Grouped by function (Connection, Credentials, Display, Options)
- **Section headers**: Uppercase labels with icons for quick scanning
- **Status bar**: Bottom of sidebar with connection state and resolution

### Interaction Patterns

- **Hover states**: Subtle scale animations on buttons
- **Status colors**: Gray (disconnected), Orange (connecting), Green (connected), Red (failed)
- **Resolution presets**: Quick-select buttons for common resolutions (720p, 1080p, 1440p)

### Accessibility

- Uses system colors (`NSColor.windowBackgroundColor`, etc.) for dark mode support
- Proper contrast ratios with `.secondary` and `.tertiary` text styles
- Help tooltips on icon-only buttons

## Code Style

### SwiftUI Views

- Extract complex views into computed properties (`private var sidebar: some View`)
- Use `@ViewBuilder` for reusable components (`FormSection`, `FormField`)
- Prefer `.frame(maxWidth: .infinity)` over fixed widths for flexibility

### State Management

- `@StateObject` for session (owned by view)
- `@State` for local UI state (form fields, hover states)
- `@Published` in `RdpSession` for observable changes

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
# Ensure pkg-config can find freerdp3
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"

# Build and run
swift run MacRDP
```

## Key Files for UI Changes

| File | Purpose |
|------|---------|
| `ContentView.swift` | Main layout, sidebar, form sections, action buttons |
| `MacRDPApp.swift` | Window configuration, menu commands |
| `RdpCanvasView.swift` | Frame rendering, mouse/keyboard input |
| `RdpSession.swift` | Connection state, frame handling |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+S` | Toggle sidebar |
| `Cmd+O` | Import .rdp file |
| `Cmd+Return` | Connect |
| `Cmd+Shift+D` | Disconnect |

## Future Improvements

- [ ] Connection history/favorites persistence
- [x] Keyboard shortcut for sidebar toggle (Cmd+Shift+S)
- [ ] Full-screen mode with auto-hiding sidebar
- [ ] Clipboard sharing support
- [ ] Multi-monitor support
- [ ] Certificate validation UI
