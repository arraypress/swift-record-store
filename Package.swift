// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-record-store",
    // SQLite and Foundation only, so it runs anywhere an app does. The floor
    // is the fleet's: OSAllocatedUnfairLock and the value-type format styles.
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RecordStore", targets: ["RecordStore"]),
    ],
    targets: [
        .target(name: "RecordStore"),
        // Fixtures/v0.1.2.sqlite was written by store 0.1.1 over this library's
        // 0.1.2: every later version must open it and keep working.
        .testTarget(name: "RecordStoreTests", dependencies: ["RecordStore"], resources: [.copy("Fixtures")]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
