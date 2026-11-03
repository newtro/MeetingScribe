// swift-tools-version: 6.2
import PackageDescription

// Built by ./build.sh, which wraps the binary into build/MeetingScribe.app. Don't run the bare
// executable from .build/ for capture — TCC grants attach to the signed bundle.
let package = Package(
    name: "MeetingScribe",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Unified streaming ASR/timings + Nemotron 3 diarization; no TTS or text-normalization engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: ["Diarizer"]),
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
