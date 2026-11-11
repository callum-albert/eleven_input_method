// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ElevenInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ElevenCore", targets: ["ElevenCore"]),
        .executable(name: "ElevenInput", targets: ["ElevenIME"]),
        .executable(name: "eleven-probe", targets: ["ElevenProbe"]),
        .executable(name: "ElevenDemo", targets: ["ElevenDemo"]),
    ],
    targets: [
        .target(name: "ElevenCore"),
        .executableTarget(
            name: "ElevenIME",
            dependencies: ["ElevenCore"],
            linkerSettings: [
                .linkedFramework("InputMethodKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
            ]
        ),
        .executableTarget(name: "ElevenProbe", dependencies: ["ElevenCore"]),
        .executableTarget(
            name: "ElevenDemo",
            dependencies: ["ElevenCore"],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(name: "ElevenSelfTest", dependencies: ["ElevenCore"], path: "Tests/SelfTest"),
    ],
    swiftLanguageVersions: [.v5]
)
