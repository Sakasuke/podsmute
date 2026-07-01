// swift-tools-version:5.9
//
//  Package.swift
//  PodsMute
//
//  Swift Package Manager build so the app can be compiled with the Command Line
//  Tools alone (no full Xcode / xcodegen required). The SwiftUI @main entry point
//  (App/PodsMuteApp.swift) is excluded; the SPM executable uses App/main.swift,
//  a plain AppKit entry point instead.
//
import PackageDescription

let package = Package(
    name: "PodsMute",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // C shim that re-exports <notify.h> (notify_register_dispatch, etc.).
        .target(
            name: "CNotify",
            path: "CNotify"
        ),
        .executableTarget(
            name: "PodsMute",
            dependencies: ["CNotify"],
            path: "PodsMute",
            exclude: [
                "App/PodsMuteApp.swift",   // SwiftUI @main — used only by the Xcode build
                "App/Info.plist",
                "PodsMute.entitlements",
                "Bridge",                  // Obj-C bridging header — not needed for SPM
                "Resources"
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOBluetooth")
            ]
        )
    ]
)
