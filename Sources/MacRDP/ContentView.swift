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
    @State private var showPassword = false
    @State private var connectingRotation: Double = 0
    @State private var sharedFolderPath = ""
    @State private var sharedFolderName = "Mac"
    @State private var timeoutSeconds: UInt32 = 30

    private let sidebarWidth: CGFloat = 300
    private let timeoutOptions: [(String, UInt32)] = [
        ("10 sec", 10),
        ("30 sec", 30),
        ("60 sec", 60),
        ("2 min", 120),
        ("No limit", 0)
    ]

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
        .sheet(item: $session.pendingCertificate) { cert in
            CertificateSheet(cert: cert, session: session)
        }
        .onChange(of: isConnected) { connected in
            // Auto-collapse sidebar when connected, show when disconnected
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showSidebar = !connected
            }
        }
    }

    private var isConnecting: Bool {
        if case .connecting = session.state { return true }
        return false
    }

    private var canvasArea: some View {
        ZStack {
            canvasBackground

            if session.frame != nil {
                RdpCanvasView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isConnecting {
                connectingView
            } else {
                emptyStateView
            }

            // Floating toolbar
            VStack {
                HStack(spacing: 8) {
                    if !isConnected {
                        sidebarToggle
                    }
                    
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

    private var connectingView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 4)
                    .frame(width: 64, height: 64)
                
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(connectingRotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            connectingRotation = 360
                        }
                    }
                
                Image(systemName: "network")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(spacing: 8) {
                Text("Connecting to \(host)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text("Establishing secure RDP connection...")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            
            Button {
                session.disconnect()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var floatingToolbar: some View {
        HStack(spacing: 8) {
            if session.remoteSize != .zero {
                Text("\(Int(session.remoteSize.width))×\(Int(session.remoteSize.height))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            
            if session.rttMs >= 0 {
                latencyIndicator
            }
            
            Divider()
                .frame(height: 16)
            
            fullscreenToggle
            disconnectButton
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
    }
    
    private var latencyIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: latencyIcon)
                .font(.system(size: 10))
                .foregroundStyle(latencyColor)
            Text("\(session.rttMs)ms")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .help("Network latency (round-trip time)")
    }
    
    private var latencyIcon: String {
        switch session.rttMs {
        case ..<50: return "wifi"
        case ..<100: return "wifi"
        case ..<200: return "wifi.exclamationmark"
        default: return "wifi.exclamationmark"
        }
    }
    
    private var latencyColor: Color {
        switch session.rttMs {
        case ..<50: return .green
        case ..<100: return .yellow
        case ..<200: return .orange
        default: return .red
        }
    }

    private var disconnectButton: some View {
        Button {
            session.disconnect()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color.red, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Disconnect (Cmd+Shift+D)")
    }

    private var canvasBackground: some View {
        ZStack {
            // Dark background when connected, system background when disconnected
            if session.frame != nil {
                Color.black
            } else {
                Color(nsColor: .windowBackgroundColor)
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
                    fileSharingSection
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
        password = conn.password
        domain = conn.domain
        width = conn.width
        height = conn.height
        enableNLA = conn.enableNLA
        allowGFX = conn.allowGFX
        sharedFolderPath = conn.sharedFolderPath
        sharedFolderName = conn.sharedFolderName
        timeoutSeconds = conn.timeoutSeconds
    }

    private func saveCurrentConnection() {
        guard !host.isEmpty else { return }
        let conn = SavedConnection(
            host: host,
            port: port,
            username: username,
            password: password,
            domain: domain,
            width: width,
            height: height,
            enableNLA: enableNLA,
            allowGFX: allowGFX,
            sharedFolderPath: sharedFolderPath,
            sharedFolderName: sharedFolderName,
            timeoutSeconds: timeoutSeconds
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

                HStack(spacing: 8) {
                    FormField(label: "Password", icon: "lock") {
                        if showPassword {
                            TextField("password", text: $password)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField("••••••••", text: $password)
                                .textFieldStyle(.plain)
                        }
                    }
                    
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? "Hide password" : "Show password")
                    .padding(.top, 16)
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

                Divider()
                    .padding(.vertical, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection Timeout")
                            .font(.system(size: 12, weight: .medium))
                        Text("Time to wait before giving up")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $timeoutSeconds) {
                        ForEach(timeoutOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
            }
        }
    }

    private var fileSharingSection: some View {
        FormSection(title: "File Sharing", icon: "folder") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Share a local folder with the remote Windows session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("Folder path", text: $sharedFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Button {
                        selectSharedFolder()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.borderless)
                    .help("Choose folder")
                }

                if !sharedFolderPath.isEmpty {
                    HStack(spacing: 8) {
                        Text("Name on Windows:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        TextField("Mac", text: $sharedFolderName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 80)

                        Spacer()

                        Button {
                            sharedFolderPath = ""
                            sharedFolderName = "Mac"
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear shared folder")
                    }

                    Text("Access via " + #"\\tsclient\"# + (sharedFolderName.isEmpty ? "Mac" : sharedFolderName))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func selectSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"
        panel.message = "Choose a folder to share with the remote Windows session"

        // Default to Downloads if no path set
        if sharedFolderPath.isEmpty {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        } else {
            let expandedPath = (sharedFolderPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expandedPath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            sharedFolderPath = url.path
            // Use folder name as default share name if not set
            if sharedFolderName == "Mac" || sharedFolderName.isEmpty {
                sharedFolderName = url.lastPathComponent
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
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(connectButtonDisabled ? Color.accentColor.opacity(0.5) : Color.accentColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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
            
            if case .failed = session.state {
                Button {
                    connect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Retry connection")
            }
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
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
            }

            VStack(spacing: 8) {
                Text("Ready to Connect")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Enter your server details in the sidebar\nand click Connect to start a session")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            
            if !showSidebar {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showSidebar = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sidebar.left")
                        Text("Show Sidebar")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
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
            allowGFX: allowGFX,
            sharedFolderPath: sharedFolderPath.isEmpty ? nil : sharedFolderPath,
            sharedFolderName: sharedFolderName.isEmpty ? nil : sharedFolderName,
            timeoutSeconds: timeoutSeconds
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

struct CertificateSheet: View {
    let cert: CertificateInfo
    let session: RdpSession
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: cert.isChanged ? "exclamationmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(cert.isChanged ? .red : .orange)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(cert.isChanged ? "Certificate Changed" : "Verify Certificate")
                        .font(.headline)
                    Text(cert.isChanged 
                         ? "The server's certificate has changed since your last connection."
                         : "The server presented a certificate that needs verification.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CertField(label: "Host", value: "\(cert.host):\(cert.port)")
                    CertField(label: "Common Name", value: cert.commonName)
                    CertField(label: "Subject", value: cert.subject)
                    CertField(label: "Issuer", value: cert.issuer)
                    CertField(label: "Fingerprint", value: cert.fingerprint, monospace: true)
                    
                    if cert.isChanged, let oldFp = cert.oldFingerprint {
                        Divider()
                        Text("Previous Certificate")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        CertField(label: "Old Fingerprint", value: oldFp, monospace: true)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)
            
            Divider()
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    session.rejectCertificate()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Trust Once") {
                    session.acceptCertificate(permanently: false)
                    dismiss()
                }
                
                Button("Always Trust") {
                    session.acceptCertificate(permanently: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500)
        .interactiveDismissDisabled()
    }
}

private struct CertField: View {
    let label: String
    let value: String
    var monospace: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(monospace ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
        }
    }
}
