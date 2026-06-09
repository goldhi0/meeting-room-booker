// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingRoomBooker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MeetingRoomBooker",
            path: "Sources/MeetingRoomBooker",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
