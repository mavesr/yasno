// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Yasno",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Yasno", targets: ["SwitchApp"]),
               .executable(name: "YasnoValidate", targets: ["ValidationRunner"])],
    targets: [
        .target(name: "SwitchCore", resources: [.copy("Resources")]),
        .executableTarget(name: "SwitchApp", dependencies: ["SwitchCore"]),
        .target(name: "SwitchValidation", dependencies: ["SwitchCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "ValidationRunner", dependencies: ["SwitchValidation"]),
        .testTarget(name: "SwitchValidationTests", dependencies: ["SwitchValidation", "SwitchCore"]),
        .testTarget(name: "SwitchCoreTests", dependencies: ["SwitchCore"]),
        .testTarget(name: "SwitchAppTests", dependencies: ["SwitchApp", "SwitchCore"])
    ]
)
