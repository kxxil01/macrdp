import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MacRDPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Mac RDP") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    configureWindow()
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            CommandMenu("Connection") {
                Button("Import .rdp File...") {
                    NotificationCenter.default.post(name: .importRdpFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Divider()

                Button("Connect") {
                    NotificationCenter.default.post(name: .connect, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Disconnect") {
                    NotificationCenter.default.post(name: .disconnect, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }

    private func configureWindow() {
        guard let window = NSApp.windows.first else { return }
        window.center()
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(nil)
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let importRdpFile = Notification.Name("importRdpFile")
    static let connect = Notification.Name("connect")
    static let disconnect = Notification.Name("disconnect")
}
