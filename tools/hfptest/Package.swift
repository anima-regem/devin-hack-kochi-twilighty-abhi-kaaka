// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hfptest",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "hfptest",
            path: "Sources/hfptest",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                // Embed Info.plist (NSBluetoothAlwaysUsageDescription etc.) into the binary,
                // so TCC doesn't kill the process when it touches Bluetooth.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Info.plist"]),
            ]
        )
    ]
)
