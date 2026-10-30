// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentNotifier",
    platforms: [.macOS(.v13)],
    targets: [
        // LibZSTD（zstd 解压源码，DeepSeek Harness 面板用）暂不编入：构建权限未放行，
        // 恢复时把下面的 target 定义加回并让 AgentNotifier 依赖它：
        // .target(name: "LibZSTD", path: "Sources/LibZSTD",
        //         exclude: ["decompress/huf_decompress_amd64.S"],
        //         cSettings: [.define("ZSTD_LEGACY_SUPPORT", to: "0"),
        //                     .define("ZSTD_DISABLE_ASM"),
        //                     .headerSearchPath("common"),
        //                     .headerSearchPath("decompress")]),
        // main.swift 侧已有 #if canImport(LibZSTD) 守护，恢复后 dsh 面板自动生效
        .executableTarget(
            name: "AgentNotifier",
            dependencies: [],
            path: "Sources/AgentNotifier"
        ),
        .testTarget(
            name: "AgentNotifierTests",
            dependencies: ["AgentNotifier"],
            path: "Tests/AgentNotifierTests"
        )
    ]
)
