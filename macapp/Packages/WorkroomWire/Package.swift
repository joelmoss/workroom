// swift-tools-version: 6.0
//
// The wire between the app and the terminal-session processes: `SessionFrame` and its codec, the
// attach and control messages, session identifiers. The app and the attach-only `workroom-session`
// tool both link it.
//
// Frozen while the attach shim ships (docs/designs/remote-workrooms.md, "WorkroomSessionProtocol is
// frozen"): its one real peer is the daemon a v2.0.0 app left running, which can never be rebuilt
// to match a change. These sources moved here byte-identical from macapp/WorkroomSessionProtocol,
// so the check is
//   git log v2.0.0..master -- macapp/WorkroomSessionProtocol/ macapp/Packages/WorkroomWire/Sources/
// and the guard is SessionShimCompatibilityTests, which runs the pinned v2.0.0 binary.
import PackageDescription

let package = Package(
  name: "WorkroomWire",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "WorkroomWire", targets: ["WorkroomWire"])
  ],
  targets: [
    .target(name: "WorkroomWire"),
    .testTarget(name: "WorkroomWireTests", dependencies: ["WorkroomWire"]),
  ]
)
