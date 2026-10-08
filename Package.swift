// swift-tools-version:5.9
import PackageDescription

// MARK: - Whisper.cpp Path Configuration (Bundled)
let whisperPath = "Vendors/whisper"
let whisperIncludePath = whisperPath + "/include"
let whisperLibPath = whisperPath + "/lib"

// MARK: - Llama.cpp Path Configuration (Bundled)
let llamaPath = "Vendors/llama"
let llamaIncludePath = llamaPath + "/include/llama"
let llamaLibPath = llamaPath + "/lib"

// MARK: - Package Definition

let package = Package(
    name: "Retrace",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Shared", targets: ["Shared"]),
        .library(name: "Database", targets: ["Database"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Processing", targets: ["Processing"]),
        .library(name: "Search", targets: ["Search"]),
        .library(name: "Migration", targets: ["Migration"]),
        .library(name: "App", targets: ["App"]),
        .library(name: "CrashRecoverySupport", targets: ["CrashRecoverySupport"]),
        .executable(name: "Retrace", targets: ["Retrace"]),
        .executable(name: "RetraceCrashRecoveryHelper", targets: ["RetraceCrashRecoveryHelper"]),
        .executable(name: "RetraceAppleScriptHelper", targets: ["RetraceAppleScriptHelper"]),
        .executable(name: "TestMostRecentFrame", targets: ["TestMostRecentFrame"]),
        .executable(name: "QueryRewindApps", targets: ["QueryRewindApps"]),
        .executable(name: "retrace-cli", targets: ["RetraceCLI"]),
    ],
    dependencies: [
        // SQLCipher for reading encrypted Rewind database and encrypted storage
        .package(url: "https://github.com/skiptools/swift-sqlcipher.git", exact: "1.7.0"),
        // Sparkle for auto-updates
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.8.1"),
        // SwiftyChrono for natural language date parsing (batmac fork with Swift 5.5+ support)
        .package(url: "https://github.com/batmac/SwiftyChrono.git", revision: "e1bf3bde0f09112909157360b6bf39302f10ae5f")
    ],
    targets: [
        // MARK: - Native C/C++ Libraries
        .systemLibrary(
            name: "CWhisper",
            path: "Vendors/whisper"
        ),
        .systemLibrary(
            name: "CLlama",
            path: "Vendors/llama"
        ),

        // MARK: - Shared models and protocols
        .target(
            name: "Shared",
            dependencies: [],
            path: "Shared"
        ),

        // MARK: - Database module
        .target(
            name: "Database",
            dependencies: [
                "Shared",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Database",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md"
            ]
        ),
        .testTarget(
            name: "DatabaseTests",
            dependencies: [
                "Database",
                "Shared",
                "Storage",
                "Processing",
                "Search"
            ],
            path: "Database/Tests",
            exclude: [
                "_future"
            ]
        ),

        // MARK: - Storage module
        .target(
            name: "Storage",
            dependencies: ["Shared"],
            path: "Storage",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md"
            ]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage", "Shared"],
            path: "Storage/Tests"
        ),

        // MARK: - Capture module
        .target(
            name: "Capture",
            dependencies: ["Shared"],
            path: "Capture",
            exclude: [
                "AppleScriptHelper",
                "Tests",
                "README.md",
                "AGENTS.md"
            ]
        ),
        .testTarget(
            name: "CaptureTests",
            dependencies: ["Capture", "Shared"],
            path: "Capture/Tests"
        ),

        // MARK: - Processing module
        .target(
            name: "Processing",
            dependencies: [
                "Shared",
                "Database",
                "Storage",
                "Search",
                "CWhisper"
            ],
            path: "Processing",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md"
            ],
            cSettings: [
                .unsafeFlags([
                    "-I" + whisperIncludePath,
                    "-I" + whisperIncludePath + "/ggml"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + whisperLibPath,
                    "-lwhisper",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "ProcessingTests",
            dependencies: ["Processing", "Shared", "Database", "Storage"],
            path: "Processing/Tests",
            cSettings: [
                .unsafeFlags([
                    "-I" + whisperIncludePath,
                    "-I" + whisperIncludePath + "/ggml"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + whisperLibPath,
                    "-lwhisper"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),

        // MARK: - Search module
        .target(
            name: "Search",
            dependencies: [
                "Shared",
                "Database",
                "CLlama"
            ],
            path: "Search",
            exclude: [
                "Tests",
                "README.md",
                "AGENTS.md"
            ],
            cSettings: [
                .unsafeFlags([
                    "-I" + llamaIncludePath
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + llamaLibPath,
                    "-lllama",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "SearchTests",
            dependencies: ["Search", "Shared", "Database"],
            path: "Search/Tests",
            cSettings: [
                .unsafeFlags([
                    "-I" + llamaIncludePath
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + llamaLibPath,
                    "-lllama"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal")
            ]
        ),

        // MARK: - Migration module
        .target(
            name: "Migration",
            dependencies: [
                "Shared",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Migration",
            exclude: [
                "README.md",
                "AGENTS.md"
            ]
        ),

        // MARK: - App integration layer
        .target(
            name: "App",
            dependencies: [
                "Shared",
                "Database",
                "Storage",
                "Capture",
                "Processing",
                "Search",
                "Migration",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "App",
            exclude: [
                "Tests",
                "README.md"
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + whisperLibPath,
                    "-lwhisper",
                    "-L" + llamaLibPath,
                    "-lllama",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                "Database",
                "Shared"
            ],
            path: "App/Tests",
            linkerSettings: [
                .unsafeFlags([
                    "-L" + whisperLibPath,
                    "-lwhisper",
                    "-L" + llamaLibPath,
                    "-lllama"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),

        // MARK: - Crash recovery support
        .target(
            name: "CrashRecoverySupport",
            dependencies: [],
            path: "UI/CrashRecoverySupport"
        ),

        // MARK: - UI module
        .executableTarget(
            name: "Retrace",
            dependencies: [
                "Shared",
                "App",
                "Database",
                "Storage",
                "Capture",
                "Processing",
                "Search",
                "Migration",
                "CrashRecoverySupport",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftyChrono", package: "SwiftyChrono")
            ],
            path: "UI",
            exclude: [
                "CrashRecoveryHelper",
                "CrashRecoverySupport",
                "LaunchAgents",
                "Tests",
                "README.md",
                "AGENTS.md",
                "Info.plist",
                "Retrace.entitlements"
            ],
            resources: [
                .process("Assets.xcassets"),
                .copy("Fonts")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L" + whisperLibPath,
                    "-lwhisper",
                    "-L" + llamaLibPath,
                    "-lllama",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("Metal")
            ]
        ),
        .executableTarget(
            name: "RetraceCrashRecoveryHelper",
            dependencies: ["CrashRecoverySupport"],
            path: "UI/CrashRecoveryHelper",
            sources: [
                "main.swift"
            ]
        ),
        .executableTarget(
            name: "RetraceAppleScriptHelper",
            path: "Capture/AppleScriptHelper",
            sources: [
                "main.swift"
            ]
        ),

        // MARK: - Test executable for getMostRecentFrameTimestamp
        .executableTarget(
            name: "TestMostRecentFrame",
            dependencies: [
                "Shared",
                "App"
            ],
            path: "Sources/TestMostRecentFrame"
        ),

        // MARK: - AI search / indexing command-line harness (operates on a snapshot DB)
        .executableTarget(
            name: "RetraceCLI",
            dependencies: [
                "Shared",
                "Database",
                "Search",
                "Processing"
            ],
            path: "Sources/RetraceCLI"
        ),

        // MARK: - Query Rewind apps utility
        .executableTarget(
            name: "QueryRewindApps",
            dependencies: [
                "Shared",
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Sources/QueryRewindApps"
        ),
        .testTarget(
            name: "RetraceTests",
            dependencies: ["Retrace", "CrashRecoverySupport", "Shared", "App"],
            path: "UI/Tests"
        ),
    ]
)
