import Foundation
import Combine
import CoreGraphics
import Darwin
import CRDP

enum RdpConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

final class RdpSession: ObservableObject {
    @Published var state: RdpConnectionState = .disconnected
    @Published var frame: CGImage?
    @Published var remoteSize: CGSize = .zero

    private var client: OpaquePointer?
    private var userRef: UnsafeMutableRawPointer?
    private let frameQueue = DispatchQueue(label: "macrdp.frame", qos: .userInitiated)

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

            guard let handle = crdp_client_new(RdpSession.frameThunk, user, RdpSession.disconnectThunk, user) else {
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
        guard let client = client else { return }
        self.client = nil  // Clear first to prevent double-free from callback
        self.userRef = nil
        
        crdp_client_disconnect(client)
        crdp_client_free(client)
        
        DispatchQueue.main.async {
            self.state = .disconnected
            self.frame = nil
            self.remoteSize = .zero
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
                }
            }
        }
    }

    private func handleDisconnected() {
        // Clean up client resources on remote disconnect
        // Only free if client hasn't been cleared by disconnect() already
        if let client = client {
            self.client = nil
            self.userRef = nil
            crdp_client_free(client)
        }
        
        DispatchQueue.main.async {
            self.frame = nil
            self.remoteSize = .zero
            self.state = .disconnected
        }
    }
}

// MARK: - C callbacks

private extension RdpSession {
    static let frameThunk: @convention(c) (UnsafePointer<UInt8>?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void = { data, width, height, stride, user in
        guard let user else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(user).takeUnretainedValue()
        session.handleFrame(data: data, width: width, height: height, stride: stride)
    }

    static let disconnectThunk: @convention(c) (UnsafeMutableRawPointer?) -> Void = { user in
        guard let user else { return }
        let session = Unmanaged<RdpSession>.fromOpaque(user).takeUnretainedValue()
        session.handleDisconnected()
    }
}
