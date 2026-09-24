// swift-tools-version: 6.2
import PackageDescription

// Built by ./build.sh, which wraps the binary into build/MeetingScribe.app. Don't run the bare
// executable from .build/ for capture — TCC grants attach to the signed bundle.
let package = Package(
    name: "MeetingScribe",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Nemotron 3 streaming diarization on Core ML. Pinned exactly: the Nemotron 3 port is new.
        // traits: [] drops the prebuilt NeMo text-normalization engine, which only TTS/ITN use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.1", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "src",
            // Swift 5 language mode on purpose — avoids strict-concurrency churn.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
