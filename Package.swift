// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Hush",
            path: "Sources/Hush",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SoundAnalysis"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
