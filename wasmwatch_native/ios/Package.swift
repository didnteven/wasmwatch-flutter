// swift-tools-version: 5.9
import PackageDescription

// Offline host tests for the Foundation-only logic. The Flutter 3.41 default
// template uses CocoaPods for the iOS plugin itself (wasmwatch_native.podspec).
let package = Package(
  name: "WasmWatchNativeCore",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "WasmWatchNativeCore", path: "Classes",
            exclude: ["WasmWatchNativePlugin.swift"]),
    .testTarget(name: "WasmWatchNativeCoreTests", dependencies: ["WasmWatchNativeCore"], path: "Tests"),
  ]
)
