// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "photos-autorotate",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "photos-autorotate",
            dependencies: ["PhotosAutoRotateCore"],
            path: "Sources/PhotosAutoRotate"
        ),
        .target(
            name: "PhotosAutoRotateCore",
            path: "Sources/PhotosAutoRotateCore"
        ),
        .testTarget(
            name: "PhotosAutoRotateCoreTests",
            dependencies: ["PhotosAutoRotateCore"],
            path: "Tests/PhotosAutoRotateCoreTests"
        ),
    ]
)
