//
//  main.swift
//  PodsMute
//
//  AppKit entry point for the Swift Package Manager build.
//
//  The upstream project boots through SwiftUI's `@main struct PodsMuteApp: App`
//  (see App/PodsMuteApp.swift), which requires a full Xcode build. This file is
//  an equivalent plain-AppKit launcher so the exact same AppDelegate/services can
//  be compiled and run with just the Command Line Tools via `swift run` / `swift build`.
//
//  `PodsMuteApp.swift` is excluded from the SPM target in Package.swift, so there is
//  only ever one entry point per build.
//

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menu-bar-only app: no Dock icon, no main menu. When launched as a proper
// .app bundle this is reinforced by LSUIElement in Info.plist, but setting it
// here means `swift run` behaves the same way during development.
app.setActivationPolicy(.accessory)

app.run()
