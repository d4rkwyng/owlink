// swift-tools-version: 6.0
// 6.0, like Tankard: the newest tools version the macOS 14 Command Line
// Tools (Swift 6.0.x) understand. CI builds with Swift 6.1.
import PackageDescription

let checks: [SwiftSetting] = [.define("CEDRIC_CHECKS", .when(configuration: .debug))]

let package = Package(
    name: "cedric",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CedricCore", targets: ["CedricCore"]),
        .library(name: "CedricAI", targets: ["CedricAI"]),
        .executable(name: "CedricApp", targets: ["CedricApp"]),
    ],
    targets: [
        // Everything that can be tested without a window: language
        // detection, the tokenizers and highlight engine, the Markdown
        // renderer, encoding and line-ending detection, find/replace, the
        // line index, the session store and the theme palettes. Foundation
        // only; no AppKit.
        // CEDRIC_CHECKS compiles in the dev/check switches
        // (DevEnvironment.swift): on in debug builds; a release-config
        // build gets it only from Scripts/bundle-app.sh's dev default
        // (-Xswiftc -DCEDRIC_CHECKS), never from release.sh.
        .target(name: "CedricCore", swiftSettings: checks),

        // The owl's optional AI hints: Cedric's built-in engine (llama.cpp
        // + in-app model downloads from Hugging Face), Apple Intelligence's
        // on-device model, and an OpenAI-compatible client for LM Studio /
        // Ollama (localhost or LAN, never cloud); plus the "only checks so
        // often" scheduler. OFF by default.
        .target(
            name: "CedricAI",
            dependencies: ["CedricCore", "llama", "CLlamaLoader"]
        ),

        // llama.cpp's functions as pointers from dlopen/dlsym, so the app
        // doesn't load llama.framework (and Metal, Accelerate) on every
        // launch for an engine that is off by default. Headers only from
        // the binary target; see include/CLlamaLoader.h.
        .target(
            name: "CLlamaLoader",
            dependencies: ["llama"]
        ),

        // The built-in engine's inference runtime: llama.cpp's prebuilt
        // XCFramework (MIT), pinned to release b12360 by its SHA-256. The
        // macOS slice is universal (arm64 + x86_64) and embeds ggml's Metal
        // shaders as source, compiled at run time, so no `metal` compiler
        // (Xcode) is needed to build Cedric. Scripts/bundle-app.sh copies
        // llama.framework into Contents/Frameworks.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12360/llama-b12360-xcframework.zip",
            checksum: "bf45668c4f916117faea4d1f6b3adf75f31c08fa53b8b8269c4d92358c9c7b30"
        ),

        // Sparkle 2 (MIT), the updater behind Owlink › Check for Updates…:
        // its Swift Package Manager XCFramework, release 2.10.1, pinned by
        // the SHA-256 that release's own Package.swift gives. Universal
        // macOS slice, with its Autoupdate tool, Updater.app and XPC
        // services inside the framework. Only a release build embeds it
        // (Scripts/bundle-app.sh --release), and the app loads it with
        // dlopen only when its Info.plist names an update feed and key
        // (Updater.swift, docs/updates.md), so nothing of Sparkle's is
        // linked and a check build runs without it.
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
        ),

        // The AppKit app. Scripts/bundle-app.sh wraps it in "Owlink.app".
        .executableTarget(
            name: "CedricApp",
            dependencies: ["CedricCore", "CedricAI", "Sparkle"],
            // llama.framework and Sparkle.framework sit in
            // Owlink.app/Contents/Frameworks and are loaded with dlopen:
            // llama when the built-in engine first loads a model
            // (CLlamaLoader), Sparkle when updates are set up (Updater.swift).
            // -dead_strip_dylibs drops the load commands for them and the
            // frameworks only they use, since no symbol of theirs is
            // referenced.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-dead_strip_dylibs"])]
        ),

        .testTarget(
            name: "CedricCoreTests",
            dependencies: ["CedricCore"]
        ),
        .testTarget(
            name: "CedricAITests",
            dependencies: ["CedricAI", "CedricCore"]
        ),
    ]
)
