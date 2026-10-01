// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UCEdge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UCEdgeCore", targets: ["UCEdgeCore"]),
        .executable(name: "UCEdge", targets: ["UCEdge"]),
        .executable(name: "UCEdgeMenu", targets: ["UCEdgeMenu"]),
    ],
    targets: [
        .target(name: "UCEdgeCore"),
        .executableTarget(name: "UCEdge", dependencies: ["UCEdgeCore"]),
        .executableTarget(name: "UCEdgeMenu", dependencies: ["UCEdgeCore"]),
        .testTarget(name: "UCEdgeCoreTests", dependencies: ["UCEdgeCore", "UCEdge"],
                    exclude: ["Support/groundtruth.py", "Support/latchrules.py", "Support/ucassist.py", "Support/s2-crossings.json"]),
    ]
)
