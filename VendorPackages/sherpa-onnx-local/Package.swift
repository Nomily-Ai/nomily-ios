// swift-tools-version: 5.9
import PackageDescription

// ★ 2026-11-02 vendored 本地包（上游 k2-fsa/sherpa-onnx v1.13.8）。
//
// 为什么本地化：SPM 远程解析要从 GitHub release 拉 4 个 xcframework zip，
// 直连在国内超时（实测 16 分钟全挂）。把 **iOS 静态** 两个 zip 拷进
// Frameworks/（sha256 与上游 Package.swift 里的 checksum 逐一核对一致），
// Swift wrapper 原样拷贝上游 `swift-api-examples/SherpaOnnx.swift`。
// 只保留 iOS 静态产品——本项目只有 iOS 主 target 引用（手表端不引入）。
//
// 升级方法：换 Frameworks/ 里的 zip + 重拷 wrapper，改好注释里的版本号。
let package = Package(
    name: "sherpa-onnx-local",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "sherpa-onnx", targets: ["SherpaOnnx"]),
    ],
    targets: [
        // 上游 checksum: 6b8e769cb153343270fdccbe92e3b3db0d1c421d67fa0989ab01fdf5b2fcf2de
        .binaryTarget(
            name: "SherpaOnnxIOS",
            path: "Frameworks/sherpa-onnx-v1.13.8-ios-static.xcframework.zip"
        ),
        // 上游 checksum: 2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599
        .binaryTarget(
            name: "OnnxruntimeIOS",
            path: "Frameworks/onnxruntime-ios-static-xcframework-1.28.2.xcframework.zip"
        ),
        .target(
            name: "SherpaOnnx",
            dependencies: [
                .target(name: "OnnxruntimeIOS"),
                .target(name: "SherpaOnnxIOS"),
            ],
            path: "Sources/SherpaOnnxWrapper",
            sources: ["SherpaOnnx.swift"],
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
    ]
)
