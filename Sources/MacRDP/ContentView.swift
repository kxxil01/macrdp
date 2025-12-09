import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var session = RdpSession()
    @ObservedObject private var connectionStore = ConnectionStore.shared
    @State private var host = ""
    @State private var port = "3389"
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var enableNLA = true
    @State private var allowGFX = false
    @State private var showSidebar = true
    @State private var isHoveringConnect = false
    @State private var isHoveringDisconnect = false
    @State private var isFullscreen = false
    @State private var sidebarHoverArea = false
    @State private var validationError: String?
    @State private var showValidationAlert = false

    private let sidebarWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if showSidebar {
                    sidebar
                        .frame(width: sidebarWidth)
                        .background(isFullscreen ? .ultraThinMaterial : .regularMaterial)
                        .clipShape(isFullscreen ? AnyShape(RoundedRectangle(cornerRadius: 12)) : AnyShape(Rectangle()))
                        .shadow(color: isFullscreen ? .black.opacity(0.3) : .clear, radius: isFullscreen ? 20 : 0, x: 5, y: 0)
                        .padding(.leading, isFullscreen ? 8 : 0)
                        .padding(.vertical, isFullscreen ? 8 : 0)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    if !isFullscreen {
                        Divider()
                    }
                }

                canvasArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Hover area to reveal sidebar when hidden in fullscreen
            if isFullscreen && !showSidebar {
                Color.clear
                    .frame(width: 20)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showSidebar = true
                            }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSidebar)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isFullscreen)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sidebarHoverArea)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let char = event.charactersIgnoringModifiers?.lowercased()
                
                // Cmd+Shift+S: Toggle sidebar
                if mods == [.command, .shift] && char == "s" {
                    showSidebar.toggle()
                    return nil
                }
                // Cmd+Ctrl+F: Toggle fullscreen
                if mods == [.command, .control] && char == "f" {
                    toggleFullscreen()
                    return nil
                }
                // Esc: Exit fullscreen
                if event.keyCode == 53 && isFullscreen {
                    toggleFullscreen()
                    return nil
                }
                return event
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importRdpFile)) { _ in
            importRdpFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .connect)) { _ in
            if !host.isEmpty && !isConnectingOrConnected {
                connect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .disconnect)) { _ in
            if isConnected {
                session.disconnect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFullscreen)) { _ in
            toggleFullscreen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullscreen = true
            sidebarHoverArea = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullscreen = false
            sidebarHoverArea = false
        }
        .alert("Connection Error", isPresented: $showValidationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationError ?? "Please fill in all required fields")
        }
    }

    private var canvasArea: some View {
        ZStack {
            canvasBackground

            if session.frame != nil {
                RdpCanvasView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyStateView
            }

            // Floating toolbar
            VStack {
                HStack(spacing: 8) {
                    sidebarToggle
                    
                    if !showSidebar {
                        floatingStatus
                    }
                    
                    Spacer()
                    
                    if isConnected {
                        floatingToolbar
                    }
                }
                .padding(12)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var floatingToolbar: some View {
        HStack(spacing: 6) {
            fullscreenToggle
            disconnectButton
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var disconnectButton: some View {
        Button {
            session.disconnect()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.red)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Disconnect (Cmd+Shift+D)")
    }

    private var canvasBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if session.frame == nil {
                GridPattern()
                    .opacity(0.4)
            }
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            ScrollView {
                VStack(spacing: 20) {
                    if !connectionStore.connections.isEmpty {
                        recentConnectionsSection
                    }
                    connectionSection
                    credentialsSection
                    displaySection
                    optionsSection
                    actionButtons
                }
                .padding(16)
            }
            Spacer(minLength: 0)
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var recentConnectionsSection: some View {
        FormSection(title: "Recent", icon: "clock.arrow.circlepath") {
            VStack(spacing: 6) {
                ForEach(connectionStore.connections.prefix(5)) { conn in
                    RecentConnectionRow(
                        connection: conn,
                        onSelect: { loadConnection(conn) },
                        onDelete: { connectionStore.delete(conn) }
                    )
                }
            }
        }
    }

    private func loadConnection(_ conn: SavedConnection) {
        host = conn.host
        port = conn.port
        username = conn.username
        domain = conn.domain
        width = conn.width
        height = conn.height
        enableNLA = conn.enableNLA
        allowGFX = conn.allowGFX
        password = ""
    }

    private func saveCurrentConnection() {
        guard !host.isEmpty else { return }
        let conn = SavedConnection(
            host: host,
            port: port,
            username: username,
            domain: domain,
            width: width,
            height: height,
            enableNLA: enableNLA,
            allowGFX: allowGFX
        )
        connectionStore.save(conn)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
            Text("Mac RDP")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                importRdpFile()
            } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Import .rdp file")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .separatorColor).opacity(0.3))
    }

    private var connectionSection: some View {
        FormSection(title: "Connection", icon: "network") {
            VStack(spacing: 12) {
                FormField(label: "Host", icon: "server.rack") {
                    TextField("192.168.1.100", text: $host)
                        .textFieldStyle(.plain)
                }

                HStack(spacing: 12) {
                    FormField(label: "Port", icon: "number") {
                        TextField("3389", text: $port)
                            .textFieldStyle(.plain)
                    }
                    .frame(width: 80)

                    FormField(label: "Domain", icon: "building.2") {
                        TextField("Optional", text: $domain)
                            .textFieldStyle(.plain)
                    }
                }
            }
        }
    }

    private var credentialsSection: some View {
        FormSection(title: "Credentials", icon: "person.badge.key") {
            VStack(spacing: 12) {
                FormField(label: "Username", icon: "person") {
                    TextField("administrator", text: $username)
                        .textFieldStyle(.plain)
                }

                FormField(label: "Password", icon: "lock") {
                    SecureField("••••••••", text: $password)
                        .textFieldStyle(.plain)
                }
            }
        }
    }

    private var displaySection: some View {
        FormSection(title: "Display", icon: "display") {
            HStack(spacing: 12) {
                FormField(label: "Width", icon: "arrow.left.and.right") {
                    TextField("1920", text: $width)
                        .textFieldStyle(.plain)
                }

                FormField(label: "Height", icon: "arrow.up.and.down") {
                    TextField("1080", text: $height)
                        .textFieldStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                ResolutionPreset(label: "720p", width: "1280", height: "720", currentWidth: $width, currentHeight: $height)
                ResolutionPreset(label: "1080p", width: "1920", height: "1080", currentWidth: $width, currentHeight: $height)
                ResolutionPreset(label: "1440p", width: "2560", height: "1440", currentWidth: $width, currentHeight: $height)
            }
            .padding(.top, 4)
        }
    }

    private var optionsSection: some View {
        FormSection(title: "Options", icon: "gearshape") {
            VStack(spacing: 8) {
                OptionToggle(
                    title: "Network Level Authentication",
                    subtitle: "More secure, requires credentials upfront",
                    isOn: $enableNLA
                )

                OptionToggle(
                    title: "Graphics Pipeline (GFX)",
                    subtitle: "Enhanced graphics, may not work on all servers",
                    isOn: $allowGFX
                )
            }
        }
    }

    private var actionButtons: some View {
        Button {
            connect()
        } label: {
            HStack(spacing: 8) {
                if case .connecting = session.state {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: isConnected ? "arrow.triangle.2.circlepath" : "play.fill")
                }
                Text(connectButtonText)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(connectButtonDisabled ? Color.accentColor.opacity(0.5) : Color.accentColor)
        )
        .scaleEffect(isHoveringConnect && !connectButtonDisabled ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHoveringConnect)
        .onHover { isHoveringConnect = $0 }
        .disabled(connectButtonDisabled)
    }

    private var connectButtonText: String {
        switch session.state {
        case .connecting: return "Connecting..."
        case .connected: return "Reconnect"
        default: return "Connect"
        }
    }

    private var connectButtonDisabled: Bool {
        if host.isEmpty { return true }
        if case .connecting = session.state { return true }
        return false
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if isConnected, session.remoteSize != .zero {
                Text("\(Int(session.remoteSize.width))×\(Int(session.remoteSize.height))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .separatorColor).opacity(0.3))
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.3), lineWidth: 2)
            )
    }

    private var statusColor: Color {
        switch session.state {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch session.state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private var sidebarToggle: some View {
        Button {
            showSidebar.toggle()
        } label: {
            Image(systemName: showSidebar ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(showSidebar ? "Hide sidebar" : "Show sidebar")
    }

    private var floatingStatus: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var fullscreenToggle: some View {
        Button {
            toggleFullscreen()
        } label: {
            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(isFullscreen ? "Exit fullscreen (Esc)" : "Enter fullscreen (Cmd+Ctrl+F)")
    }

    private func toggleFullscreen() {
        if let window = NSApp.windows.first {
            window.toggleFullScreen(nil)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("No Active Session")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Enter connection details and click Connect")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isConnected: Bool {
        if case .connected = session.state { return true }
        return false
    }

    private var isConnectingOrConnected: Bool {
        switch session.state {
        case .connecting, .connected: return true
        default: return false
        }
    }

    private func validateConnection() -> String? {
        var missing: [String] = []
        
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            missing.append("Host")
        }
        if enableNLA {
            if username.trimmingCharacters(in: .whitespaces).isEmpty {
                missing.append("Username")
            }
            if password.isEmpty {
                missing.append("Password")
            }
        }
        
        if missing.isEmpty { return nil }
        
        if missing.count == 1 {
            return "\(missing[0]) is required"
        } else {
            return "\(missing.dropLast().joined(separator: ", ")) and \(missing.last!) are required"
        }
    }

    private func connect() {
        if let error = validateConnection() {
            validationError = error
            showValidationAlert = true
            return
        }

        let portNum = UInt16(port) ?? 3389
        let widthVal = Double(width) ?? 1920
        let heightVal = Double(height) ?? 1080

        saveCurrentConnection()

        session.connect(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNum,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            domain: domain.trimmingCharacters(in: .whitespaces),
            size: CGSize(width: widthVal, height: heightVal),
            enableNLA: enableNLA,
            allowGFX: allowGFX
        )
    }

    private func importRdpFile() {
        let panel = NSOpenPanel()
        if let rdpType = UTType(filenameExtension: "rdp") {
            panel.allowedContentTypes = [rdpType]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an RDP file to import connection settings"
        panel.prompt = "Import"
        
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            applyRdpContent(content)
        } catch {
            print("Failed to read RDP file: \(error)")
        }
    }

    private func applyRdpContent(_ content: String) {
        var newHost: String?
        var newPort: String?
        var newUser: String?
        var newDomain: String?
        var newWidth: String?
        var newHeight: String?
        var newNLA: Bool?

        let lines = content.split(whereSeparator: \.isNewline)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let key = parts[0].lowercased()
            let type = parts[1].lowercased()
            let value = parts[2]

            switch key {
            case "full address":
                let addrParts = value.split(separator: ":")
                if let first = addrParts.first {
                    newHost = String(first)
                }
                if addrParts.count > 1, let portVal = addrParts.last {
                    newPort = String(portVal)
                }
            case "username":
                newUser = value
            case "domain":
                newDomain = value
            case "desktopwidth":
                if type == "i" { newWidth = value }
            case "desktopheight":
                if type == "i" { newHeight = value }
            case "enablecredsspsupport":
                if type == "i" { newNLA = (value != "0") }
            default:
                continue
            }
        }

        if let h = newHost { host = h }
        if let p = newPort { port = p }
        if let u = newUser { username = u }
        if let d = newDomain { domain = d }
        if let w = newWidth { width = w }
        if let h = newHeight { height = h }
        if let nla = newNLA { enableNLA = nla }
    }
}

// MARK: - Supporting Views

struct FormSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            VStack(spacing: 12) {
                content
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct FormField<Content: View>: View {
    let label: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                content
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }
}

struct ResolutionPreset: View {
    let label: String
    let width: String
    let height: String
    @Binding var currentWidth: String
    @Binding var currentHeight: String

    private var isSelected: Bool {
        currentWidth == width && currentHeight == height
    }

    var body: some View {
        Button {
            currentWidth = width
            currentHeight = height
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(isSelected ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

struct OptionToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct GridPattern: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let gridSize: CGFloat = 20
                let size = geometry.size

                for x in stride(from: 0, through: size.width, by: gridSize) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }

                for y in stride(from: 0, through: size.height, by: gridSize) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
        }
    }
}

struct AnyShape: Shape {
    private let pathBuilder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

struct RecentConnectionRow: View {
    let connection: SavedConnection
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !connection.username.isEmpty {
                        Text(connection.username)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Text(timeAgo(connection.lastUsed))
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
            }

            Spacer()

            if isHovering {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from history")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { isHovering = $0 }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        return "\(Int(interval / 604800))w ago"
    }
}
