import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var session = RdpSession()
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

    private let sidebarWidth: CGFloat = 280

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            ZStack {
                canvasBackground
                RdpCanvasView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if session.frame == nil {
                    emptyStateView
                }

                VStack {
                    HStack {
                        sidebarToggle
                        Spacer()
                        if !showSidebar {
                            floatingStatus
                        }
                    }
                    .padding(12)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showSidebar)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "s" {
                    showSidebar.toggle()
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
        VStack(spacing: 10) {
            Button {
                connect()
            } label: {
                HStack(spacing: 8) {
                    if case .connecting = session.state {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isConnectingOrConnected ? "Connecting..." : "Connect")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(host.isEmpty || isConnectingOrConnected ? Color.accentColor.opacity(0.5) : Color.accentColor)
            )
            .scaleEffect(isHoveringConnect && !host.isEmpty && !isConnectingOrConnected ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHoveringConnect)
            .onHover { isHoveringConnect = $0 }
            .disabled(host.isEmpty || isConnectingOrConnected)

            if isConnected {
                Button {
                    session.disconnect()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                        Text("Disconnect")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.red, lineWidth: 1.5)
                )
                .scaleEffect(isHoveringDisconnect ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHoveringDisconnect)
                .onHover { isHoveringDisconnect = $0 }
            }
        }
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

    private func connect() {
        let portNum = UInt16(port) ?? 3389
        let widthVal = Double(width) ?? 1920
        let heightVal = Double(height) ?? 1080

        session.connect(
            host: host,
            port: portNum,
            username: username,
            password: password,
            domain: domain,
            size: CGSize(width: widthVal, height: heightVal),
            enableNLA: enableNLA,
            allowGFX: allowGFX
        )
    }

    private func importRdpFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "rdp")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        guard let content = try? String(contentsOf: url) else { return }
        applyRdpContent(content)
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
