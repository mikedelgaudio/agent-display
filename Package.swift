// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "agent-display",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agent-display", targets: ["agent-display"]),
    ],
    targets: [
        // Header-only declarations for the private CGVirtualDisplay classes in CoreGraphics.
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "agent-display",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/agent-display",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
