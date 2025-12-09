// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac-rdp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacRDP", targets: ["MacRDP"])
    ],
    targets: [
        // System library target to pull headers/libs from Homebrew's freerdp via pkg-config
        .systemLibrary(
            name: "CFREERDP",
            pkgConfig: "freerdp3",
            providers: [
                .brew(["freerdp"])
            ]
        ),
        // C shim that wraps FreeRDP in a small, Swift-friendly API
        .target(
            name: "CRDP",
            dependencies: ["CFREERDP"],
            path: "Sources/CRDP",
            publicHeadersPath: "include",
            cSettings: [
                .define("WINPR_ENABLE_OPENSSL"),
                // Fallback include paths for Homebrew (pkg-config preferred)
                .unsafeFlags([
                    "-I/opt/homebrew/include/freerdp3",
                    "-I/opt/homebrew/include/winpr3",
                    "-I/usr/local/include/freerdp3",
                    "-I/usr/local/include/winpr3",
                    "-I/opt/homebrew/include",
                    "-I/usr/local/include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-L/usr/local/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"
                ]),
                .linkedLibrary("freerdp-client3"),
                .linkedLibrary("freerdp3"),
                .linkedLibrary("winpr3"),
                .linkedFramework("AppKit")
            ]
        ),
        // SwiftUI executable that consumes the shim
        .executableTarget(
            name: "MacRDP",
            dependencies: ["CRDP"],
            path: "Sources/MacRDP"
        )
    ]
)
