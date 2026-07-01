//
//  AudioAccessoryMonitor.swift
//  PodsMute
//
//  Monitors audioaccessoryd Darwin notifications for AirPods mute-gesture events.
//  When you press the AirPods Pro stem (or AirPods Max crown) during a call, macOS's
//  audioaccessoryd emits a Darwin notification. We catch it and toggle the system mic.
//
//  Fork changes (Airpods-mute):
//    - Delivery via `notify_register_dispatch` (a dispatch source on a background queue)
//      instead of `CFNotificationCenterAddObserver`. The CFNotificationCenter Darwin
//      observer is serviced by the main run loop, which macOS throttles when this
//      background (LSUIElement) app is idle / App-Napped — so presses were silently
//      dropped until something else woke the app. A dispatch source is not tied to the
//      run loop and fires reliably even while the app is idle.
//    - Coalesce/debounce rapid duplicate notifications so one physical press = one toggle,
//      and suppress the "echo" that fires right after WE change the mute state.
//    - Speculative/extra notification names and the noisy distributed-center listeners
//      are gated behind `debugMode` (off by default).
//    - Diagnostics go through os.Logger so they're visible in Console.app even when the
//      app is launched as a bundle (where stdout/print is not visible).
//

import Foundation
import Darwin
import CNotify
import os

/// Monitors Darwin notifications from audioaccessoryd for AirPods mute-gesture events.
final class AudioAccessoryMonitor {

    // MARK: - Types

    enum MuteState {
        case muted
        case unmuted
        case unknown
    }

    // MARK: - Public configuration

    /// Callback fired when an AirPods mute gesture is detected. Invoked on a background
    /// dispatch queue (NOT the main queue) so the handler can mute immediately without
    /// waiting for the possibly-throttled main run loop; the handler is responsible for
    /// hopping to main for any UI work.
    var onMuteStateChanged: ((MuteState) -> Void)?

    /// Debug callback for every raw notification name that is received.
    var onNotification: ((String) -> Void)?

    /// When true, also registers the speculative extra notification names and the
    /// distributed-center listeners, and logs every notification. Useful for figuring
    /// out which notification your macOS version actually posts. Off by default because
    /// the extra listeners are noisy and can echo our own mute changes.
    var debugMode: Bool = false

    /// Minimum time between two accepted toggles. Kills the echo that audioaccessoryd /
    /// CoreAudio emit right after we set the mute property, while still allowing a real
    /// human double-press (which is always slower than this).
    var debounceInterval: TimeInterval = 0.3

    // MARK: - Private state

    private var isMonitoring = false
    private var lastAcceptedEvent: TimeInterval = 0
    private var tokens: [Int32] = []
    private let queue = DispatchQueue(label: "com.podsmute.app.notify")
    private let log = Logger(subsystem: "com.podsmute.app", category: "AudioAccessoryMonitor")

    /// The notification audioaccessoryd posts when the AirPods mute state changes.
    private let primaryNotification = "com.apple.audioaccessoryd.MuteState"

    /// Extra names to *also* watch when `debugMode` is on. These are speculative — some
    /// may never fire, and some ("…mute.changed") can be echoes of our own change, so
    /// they are only enabled for diagnostics.
    private let debugExtraNotifications = [
        "com.apple.AudioAccessory.cdMsgNotification",
        "com.apple.audio.device.mute.changed",
        "com.apple.coreaudio.defaultdevicechanged",
        "com.apple.audio.MuteStateChanged",
        "AAMuteStateChanged",
    ]

    // MARK: - Init

    init() {}

    deinit { stopMonitoring() }

    // MARK: - Public methods

    @discardableResult
    func startMonitoring() -> Bool {
        guard !isMonitoring else {
            log.debug("Already monitoring")
            return true
        }

        // Always listen for the primary mute-state notification.
        registerDispatch(primaryNotification)

        // In debug mode, cast a wider net to help discover the right name / behaviour.
        if debugMode {
            for name in debugExtraNotifications {
                registerDispatch(name)
            }
            registerDistributedNotifications()
        }

        isMonitoring = true
        log.info("Started monitoring. Listening for \(self.primaryNotification, privacy: .public)")
        return true
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        for token in tokens {
            notify_cancel(token)
        }
        tokens.removeAll()

        if debugMode {
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDistributedCenter(),
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        isMonitoring = false
        log.info("Stopped monitoring")
    }

    // MARK: - Event handling

    /// Called (on `queue`) for every raw notification. Decides whether it represents a
    /// mute gesture and, if so, forwards a single debounced event to `onMuteStateChanged`.
    private func handleNotification(_ name: String) {
        log.debug("Notification received: \(name, privacy: .public)")
        onNotification?(name)

        // Only mute-related notifications drive a toggle.
        guard name.contains("MuteState") || name.lowercased().contains("mute") else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let sinceLast = now - lastAcceptedEvent
        guard sinceLast >= debounceInterval else {
            // Almost certainly the echo of our own mute change, or a duplicate of the
            // same physical press delivered under several notification names.
            log.debug("Ignored mute notification (debounced, \(String(format: "%.3f", sinceLast))s since last)")
            return
        }
        lastAcceptedEvent = now

        // Darwin notifications carry no payload, so we can't read the intended state —
        // the AppDelegate just toggles the current mute state. Called here on `queue`
        // (background) so the mute happens immediately even when the app is App-Napped.
        onMuteStateChanged?(.unknown)
    }

    // MARK: - Darwin notifications (dispatch-source based)

    private func registerDispatch(_ name: String) {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, queue) { [weak self] _ in
            self?.handleNotification(name)
        }
        if status == UInt32(NOTIFY_STATUS_OK) {
            tokens.append(token)
            log.debug("Registered (dispatch): \(name, privacy: .public)")
        } else {
            log.error("notify_register_dispatch failed for \(name, privacy: .public): status \(status)")
        }
    }

    // MARK: - Distributed notifications (debug only)

    private func registerDistributedNotifications() {
        let center = CFNotificationCenterGetDistributedCenter()

        let callback: CFNotificationCallback = { _, observer, name, object, _ in
            guard let observer = observer else { return }
            let monitor = Unmanaged<AudioAccessoryMonitor>.fromOpaque(observer).takeUnretainedValue()
            let notificationName = name?.rawValue as String? ?? "unknown"
            let objectStr = object.map { String(describing: $0) } ?? "nil"
            monitor.log.debug("Distributed: \(notificationName, privacy: .public) object=\(objectStr, privacy: .public)")
            monitor.queue.async { monitor.handleNotification("Distributed:\(notificationName)") }
        }

        for name in [primaryNotification, "com.apple.audio.MuteStateChanged", "AAMuteStateChanged"] {
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                callback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }
}
