import Foundation
import Combine
import CoreGraphics
import Darwin
import CRDP

enum RdpDisconnectReason: Int32 {
    case user = 0
    case server = 1
    case network = 2
    case logoff = 3
    case idle = 4
    case admin = 5
    case connectFailed = 6
    case unknown = 99
    
    var message: String {
        switch self {
        case .user: return "Disconnected"
        case .server: return "Server closed the connection"
        case .network: return "Network connection lost"
        case .logoff: return "Session ended (logged off)"
        case .idle: return "Session timed out due to inactivity"
        case .admin: return "Disconnected by administrator"
        case .connectFailed: return "Connection failed"
        case .unknown: return "Connection lost"
        }
    }
}

enum RdpConnectionState: Equatable {
    case disconnected
    case disconnectedWithReason(RdpDisconnectReason)
    case connecting
    case connected
    case failed(String)
}

struct CertificateInfo: Identifiable {
    let id = Foundation.UUID()
    let host: String
    let port: UInt16
    let commonName: String
    let subject: String
    let issuer: String
    let fingerprint: String
    let isChanged: Bool
    let oldFingerprint: String?
}

final class RdpSession: ObservableObject {
    @Published var state: RdpConnectionState = .disconnected
    @Published var frame: CGImage?
    @Published var remoteSize: CGSize = .zero
    @Published var pendingCertificate: CertificateInfo?
    @Published var rttMs: Int32 = -1  // Round-trip time in ms, -1 if unavailable
    
    private var client: OpaquePointer?
    private var rttTimer: Timer?
    private var userRef: UnsafeMutableRawPointer?
    private let frameQueue = DispatchQueue(label: "macrdp.frame", qos: .userInitiated)
    
    // Semaphore to block FreeRDP thread while waiting for cert decision
    private var certSemaphore = DispatchSemaphore(value: 0)
    private var certDecision: Int32 = 0 // 0=reject, 1=accept permanently, 2=accept session

    deinit {
        disconnect()
    }

    func connect(host: String,
                 port: UInt16,
                 username: String,
                 password: String,
                 domain: String?,
                 size: CGSize,
                 enableNLA: Bool,
                 allowGFX: Bool,
                 sharedFolderPath: String? = nil,
                 sharedFolderName: String? = nil,
                 timeoutSeconds: UInt32 = 30) {
        disconnect()
        
        DispatchQueue.main.async {
            self.state = .connecting
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let user = Unmanaged.passUnretained(self).toOpaque()
            self.userRef = user

            guard let handle = crdp_client_new(RdpSession.frameThunk, user, RdpSession.disconnectThunk, user, RdpSession.certThunk, user) else {
                DispatchQueue.main.async {
                    self.state = .failed("Unable to create session")
                }
                return
            }
            self.client = handle

            let hostC = strdup(host)
            let userC = username.isEmpty ? nil : strdup(username)
            let passC = password.isEmpty ? nil : strdup(password)
            let domainC = (domain?.isEmpty == false) ? strdup(domain!) : nil
            
            // Drive redirection - validate and prepare path
            var drivePathC: UnsafeMutablePointer<CChar>? = nil
            var driveNameC: UnsafeMutablePointer<CChar>? = nil
            
            if let folderPath = sharedFolderPath, !folderPath.isEmpty {
                // Expand ~ to home directory if needed
                let expandedPath = (folderPath as NSString).expandingTildeInPath
                
                // Verify path exists and is a directory
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDir), isDir.boolValue {
                    drivePathC = strdup(expandedPath)
                    driveNameC = strdup(sharedFolderName ?? "Mac")
                }
            }

            var cfg = crdp_config_t(host: hostC,
                                    port: port,
                                    username: userC,
                                    password: passC,
                                    domain: domainC,
                                    width: UInt32(size.width),
                                    height: UInt32(size.height),
                                    enable_nla: enableNLA,
                                    allow_gfx: allowGFX,
                                    drive_path: drivePathC,
                                    drive_name: driveNameC,
                                    timeout_seconds: timeoutSeconds)

            let result = crdp_client_connect(handle, &cfg)
            free(hostC)
            free(userC)
            free(passC)
            free(domainC)
            free(drivePathC)
            free(driveNameC)

            if result != 0 {
                DispatchQueue.main.async {
                    self.state = .failed("Connection failed (error \(result))")
                }
                crdp_client_free(handle)
                self.client = nil
                return
            }
        }
    }

    func disconnect() {
        stopRttTimer()
        
        guard let client = client else { return }
        self.client = nil  // Clear first to prevent double-free from callback
        self.userRef = nil
        
        crdp_client_disconnect(client)
        crdp_client_free(client)
        
        DispatchQueue.main.async {
            self.state = .disconnected
            self.frame = nil
            self.remoteSize = .zero
            self.rttMs = -1
        }
    }

    func sendPointer(flags: UInt16, x: UInt16, y: UInt16) {
        guard let client = client else { return }
        crdp_send_pointer_event(client, flags, x, y)
    }

    func sendKey(flags: UInt16, scancode: UInt16) {
        guard let client = client else { return }
        crdp_send_keyboard_event(client, flags, scancode)
    }

    private func handleFrame(data: UnsafePointer<UInt8>?, width: UInt32, height: UInt32, stride: UInt32) {
        guard let data else { return }
        let byteCount = Int(stride * height)
        let buffer = Data(bytes: data, count: byteCount)
        frameQueue.async {
            guard let provider = CGDataProvider(data: buffer as CFData) else { return }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let alpha = CGImageAlphaInfo.premultipliedFirst.rawValue
            let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | alpha)
            guard let image = CGImage(width: Int(width),
                                      height: Int(height),
                                      bitsPerComponent: 8,
                                      bitsPerPixel: 32,
                                      bytesPerRow: Int(stride),
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo,
                                      provider: provider,
                                      decode: nil,
                                      shouldInterpolate: true,
                                      intent: .defaultIntent) else { return }

            DispatchQueue.main.async {
                self.remoteSize = CGSize(width: Int(width), height: Int(height))
                self.frame = image
                if case .connecting = self.state {
                    self.state = .connected
                    self.startRttTimer()
                }
            }
        }
    }

    private func handleDisconnected(reason: Int32) {
        // Clean up client resources on remote disconnect
        // Only free if client hasn't been cleared by disconnect() already
        if let client = client {
            self.client = nil
            self.userRef = nil
            crdp_client_free(client)
        }
        
        let disconnectReason = RdpDisconnectReason(rawValue: reason) ?? .unknown
        
        DispatchQueue.main.async {
            self.stopRttTimer()
            self.frame = nil
            self.remoteSize = .zero
            self.rttMs = -1
            
            // Show reason if it's not a user-initiated disconnect
            if disconnectReason == .user {
                self.state = .disconnected
            } else {
                self.state = .disconnectedWithReason(disconnectReason)
            }
        }
    }
    
    private func handleCertificate(_ certPtr: UnsafePointer<crdp_cert_info_t>) -> Int32 {
        let cert = certPtr.pointee
        let hostKey = "\(String(cString: cert.host)):\(cert.port)"
        let fingerprint = String(cString: cert.fingerprint)
        
        // Check if we already trust this certificate
        let trustedFingerprints = UserDefaults.standard.dictionary(forKey: "trustedCertificates") as? [String: String] ?? [:]
        if trustedFingerprints[hostKey] == fingerprint {
            return 2 // Accept for this session (already trusted)
        }
        
        // Build certificate info for UI
        let info = CertificateInfo(
            host: String(cString: cert.host),
            port: cert.port,
            commonName: cert.common_name != nil ? String(cString: cert.common_name) : "",
            subject: cert.subject != nil ? String(cString: cert.subject) : "",
            issuer: cert.issuer != nil ? String(cString: cert.issuer) : "",
            fingerprint: fingerprint,
            isChanged: cert.is_changed,
            oldFingerprint: cert.old_fingerprint != nil ? String(cString: cert.old_fingerprint) : nil
        )
        
        // Reset semaphore state
        certDecision = 0
        
        // Show UI on main thread - use sync to ensure it's set before we wait
        // This is safe because we're on the FreeRDP background thread, not main
        DispatchQueue.main.sync {
            self.pendingCertificate = info
        }
        
        // Block until user makes a decision (with timeout to prevent hang)
        let result = certSemaphore.wait(timeout: .now() + 300) // 5 minute timeout
        
        // Clear pending certificate
        DispatchQueue.main.async {
            self.pendingCertificate = nil
        }
        
        if result == .timedOut {
            return 0 // Reject on timeout
        }
        
        return certDecision
    }
    
    func acceptCertificate(permanently: Bool) {
        if permanently, let cert = pendingCertificate {
            var trusted = UserDefaults.standard.dictionary(forKey: "trustedCertificates") as? [String: String] ?? [:]
            trusted["\(cert.host):\(cert.port)"] = cert.fingerprint
            UserDefaults.standard.set(trusted, forKey: "trustedCertificates")
        }
        certDecision = permanently ? 1 : 2
        certSemaphore.signal()
    }
    
    func rejectCertificate() {
        certDecision = 0
        certSemaphore.signal()
    }
}

// MARK: - C callbacks

private extension RdpSession {
    static let frameThunk: @convention(c) (UnsafePointer<UInt8>?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void = { data, width, height, stride, user in
        guard let user else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(user).takeUnretainedValue()
        session.handleFrame(data: data, width: width, height: height, stride: stride)
    }

    static let disconnectThunk: @convention(c) (crdp_disconnect_reason_t, UnsafeMutableRawPointer?) -> Void = { reason, user in
        guard let user else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(user).takeUnretainedValue()
        session.handleDisconnected(reason: Int32(reason.rawValue))
    }
    
    static let certThunk: @convention(c) (UnsafePointer<crdp_cert_info_t>?, UnsafeMutableRawPointer?) -> Int32 = { cert, user in
        guard let cert, let user else { return 0 }
        let session = Unmanaged<RdpSession>.fromOpaque(user).takeUnretainedValue()
        return session.handleCertificate(cert)
    }
    
    func startRttTimer() {
        rttTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateRtt()
        }
    }
    
    func stopRttTimer() {
        rttTimer?.invalidate()
        rttTimer = nil
    }
    
    func updateRtt() {
        guard let client = client else { return }
        let rtt = crdp_get_rtt_ms(client)
        DispatchQueue.main.async {
            // Only update if we got a valid value, keep last known otherwise
            if rtt >= 0 {
                self.rttMs = rtt
            }
        }
    }
}
