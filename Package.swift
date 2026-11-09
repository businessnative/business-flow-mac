// swift-tools-version:5.9
import PackageDescription

// A macOS app AppKitet linkel. A manifestet a gazda gépen értékeljük ki, ezért Linuxon
// (egységteszt) az executable target kimarad; macOS-en a terméklista változatlan.
#if os(macOS)
let bnDeps: [Package.Dependency] = []
let coreDeps: [Target.Dependency] = []
let bnProducts: [Product] = [
    .executable(name: "BNFlow", targets: ["BNFlow"]),
    .library(name: "BNFlowCore", targets: ["BNFlowCore"]),
]
let bnAppTargets: [Target] = [
    .executableTarget(
        name: "BNFlow",
        dependencies: ["BNFlowCore"],
        linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"),
            .linkedFramework("AudioToolbox"), .linkedFramework("ApplicationServices"), .linkedFramework("Security"),
            .linkedFramework("ServiceManagement"), .linkedFramework("CoreText"),
        ]
    ),
]
#else
let bnDeps: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
]
let coreDeps: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
]
let bnProducts: [Product] = [
    .library(name: "BNFlowCore", targets: ["BNFlowCore"]),
]
let bnAppTargets: [Target] = []
#endif

let package = Package(
    name: "BNFlow",
    platforms: [.macOS(.v14)],
    products: bnProducts,
    dependencies: bnDeps,
    targets: [
        .target(name: "BNFlowCore", dependencies: coreDeps),
    ] + bnAppTargets + [
        .testTarget(name: "BNFlowCoreTests", dependencies: ["BNFlowCore"]),
    ]
)
