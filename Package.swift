// swift-tools-version: 5.10
import PackageDescription

#if os(Linux)
// Linux: the same SwitchCore (detector, dictionaries, layouts) and its tests, with the
// Linux application in Sources/LinuxApp instead of the macOS one.
let package = Package(
    name: "Yasno",
    products: [.executable(name: "yasno", targets: ["LinuxApp"]),
               .executable(name: "YasnoValidate", targets: ["ValidationRunner"])],
    targets: [
        .target(name: "SwitchCore", resources: [.copy("Resources")]),
        .systemLibrary(name: "CGtk3", pkgConfig: "gtk+-3.0", providers: [.apt(["libgtk-3-dev"])]),
        .systemLibrary(name: "CXkbCommon", pkgConfig: "xkbcommon", providers: [.apt(["libxkbcommon-dev"])]),
        .target(name: "CYasnoLinux", dependencies: ["CGtk3", "CXkbCommon"],
                cSettings: [.unsafeFlags(["-Wno-deprecated-declarations"])],
                linkerSettings: [.linkedLibrary("dl")]),
        .target(name: "YasnoLinux", dependencies: ["SwitchCore", "CYasnoLinux"]),
        .executableTarget(name: "LinuxApp", dependencies: ["YasnoLinux"]),
        .target(name: "SwitchValidation", dependencies: ["SwitchCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "ValidationRunner", dependencies: ["SwitchValidation"]),
        .testTarget(name: "SwitchValidationTests", dependencies: ["SwitchValidation", "SwitchCore"]),
        .testTarget(name: "SwitchCoreTests", dependencies: ["SwitchCore"]),
        .testTarget(name: "LinuxAppTests", dependencies: ["YasnoLinux", "SwitchCore"])
    ]
)
#else
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
#endif
