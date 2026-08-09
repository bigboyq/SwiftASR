// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftASR",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .executable(
            name: "SwiftASR",
            targets: ["SwiftASR"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "SwiftASR",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            exclude: [
                "Clustering/BlockCSRGraph.swift",
                "Clustering/AccelerateSparseMatrix.swift",
                "Clustering/NativeSparseLanczos.swift"
            ],
            // Use Accelerate's macOS 13.3+ LP64 headers. Keep ILP64 disabled:
            // dense clustering is bounded at 4,096 windows and its Int32 LAPACK
            // buffers intentionally match the LP64 ABI.
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ]
        ),
        // Experimental sparse clustering is intentionally outside the app
        // target. It is available to parity/benchmark tests only and must not
        // become a production route without an explicit product decision.
        .target(
            name: "SparseClusteringExperiments",
            dependencies: ["SparseAccelerateBridge"],
            path: "Sources/SwiftASR/Clustering",
            exclude: [
                "SpectralClustering.swift",
                "SpectralGraphAlgorithms.swift",
                "SpectralSolverAlgorithms.swift",
                "SpeakerOrchestrator.swift",
                "SpeakerProfileAssembler.swift",
                "SpeakerProfileQualityRepair.swift",
                "SpeakerFragmentShadowMerger.swift"
            ],
            sources: [
                "BlockCSRGraph.swift",
                "AccelerateSparseMatrix.swift",
                "NativeSparseLanczos.swift"
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ]
        ),
        .target(
            name: "SparseAccelerateBridge",
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),
        // CIF + after_norm vDSP ports recovered from the abandoned ANE
        // experiment. Test-only dependency: the SwiftASR executable must not
        // link this target unless a future product decision revives hybrid ASR.
        .target(
            name: "CIFExperiments",
            path: "Sources/CIFExperiments",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ]
        ),
        .testTarget(
            name: "SwiftASRTests",
            dependencies: ["SwiftASR", "SparseClusteringExperiments", "CIFExperiments"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "SwiftASRModelTests",
            dependencies: ["SwiftASR", "SparseClusteringExperiments"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])
            ]
        ),
    ]
)
