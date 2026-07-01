//
//  GlobalHotKey.swift
//  PodsMute
//
//  A system-wide keyboard shortcut using Carbon's RegisterEventHotKey. This fires no
//  matter which app is frontmost and — unlike NSEvent global monitors — does NOT require
//  Accessibility / Input-Monitoring permission. It's the same mechanism used by menu-bar
//  hotkey libraries.
//
//  Fork addition (Airpods-mute): the AirPods native mute gesture can't be observed for
//  Slack/Meet/Zoom on modern macOS (those apps aren't treated as telephony "calls", so
//  the gesture never fires). A global hotkey gives reliable one-press mic mute in every
//  app, driving the same all-input-devices mute used everywhere else.
//

import AppKit
import Carbon.HIToolbox

final class GlobalHotKey {

    /// Called on the main thread when the hotkey is pressed.
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private static let signature: OSType = 0x504D5554  // 'PMUT'

    /// - Parameters:
    ///   - keyCode: a Carbon virtual key code, e.g. `kVK_ANSI_M`.
    ///   - modifiers: Carbon modifier mask, e.g. `controlKey | optionKey | cmdKey`.
    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    deinit { unregister() }

    /// Register the hotkey. Returns true on success.
    @discardableResult
    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let this = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers this on the main run loop; hop to main explicitly to be safe.
                DispatchQueue.main.async { me.onTrigger?() }
                return noErr
            },
            1, &spec, this, &handlerRef)
        guard installStatus == noErr else {
            print("[GlobalHotKey] InstallEventHandler failed: \(installStatus)")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)
        let regStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regStatus == noErr else {
            print("[GlobalHotKey] RegisterEventHotKey failed: \(regStatus)")
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
