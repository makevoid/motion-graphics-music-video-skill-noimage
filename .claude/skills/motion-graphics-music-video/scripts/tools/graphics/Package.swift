// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MotionGraphics", platforms: [.macOS(.v14)],
    products: [.library(name: "MotionGraphics", targets: ["MotionGraphics"]),
               .executable(name: "mgraphics", targets: ["mgraphics"])],
    targets: [.target(name: "MotionGraphics"),
              .executableTarget(name: "mgraphics", dependencies: ["MotionGraphics"]),
              .testTarget(name: "MotionGraphicsTests", dependencies: ["MotionGraphics"])]
)
