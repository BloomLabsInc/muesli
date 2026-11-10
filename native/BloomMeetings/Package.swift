// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BloomMeetings", platforms: [.macOS(.v15)], products: [.executable(name: "BloomMeetings", targets: ["BloomMeetings"])], dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.3")], targets: [.executableTarget(name: "BloomMeetings", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], swiftSettings: [.swiftLanguageMode(.v5)])])
