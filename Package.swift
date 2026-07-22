// swift-tools-version: 6.0
import PackageDescription

// The custom-provider API (LanguageModel / LanguageModelExecutor) is macOS 26 for
// the framework but 27.0 for these symbols, so every public type below is gated
// @available(macOS 27.0, *). The package deploys at 26 so it can sit inside an app
// that also targets 26 and only lights this provider up on 27.
let package = Package(
    name: "IliriaFoundationModels",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IliriaFoundationModels", targets: ["IliriaFoundationModels"]),
        .executable(name: "iliria-fm-verify", targets: ["iliria-fm-verify"]),
    ],
    targets: [
        .target(name: "IliriaFoundationModels"),
        .testTarget(
            name: "IliriaFoundationModelsTests",
            dependencies: ["IliriaFoundationModels"]
        ),
        // End-to-end check against a running OpenAI-compatible engine. Not a unit test:
        // it drives a real LanguageModelSession through the provider. See its --help.
        .executableTarget(
            name: "iliria-fm-verify",
            dependencies: ["IliriaFoundationModels"]
        ),
    ]
)
