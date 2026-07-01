//
//  AudioAccessoryMonitor.swift
//  PodsMute
//
//  Monitors audioaccessoryd Darwin notifications for AirPods mute-gesture events.
//  When you press the AirPods Pro stem (or AirPods Max crown) during a call, macOS's
//  audioaccessoryd emits a Darwin notification. We catch it and toggle the system mic.
//
//  Fork changes (Airpods-mute):
//    - Coalesce/debounce rapid duplicate notifications so one physical press = one toggle.
//    - Suppress the "echo" that fires immediately after WE change the mute state
//      (which would otherwise instantly undo the toggle).
//    - Speculative/extra notification names and the noisy distributed-center listeners
//      are gated behind `debugMode` (off by default) instead of always-on.
//    - Diagnostics go through os.Logger so they're visible in Console.app even when the
//      app is launched as a bundle (where stdout/print is not visible).
//

import Foundation
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

    /// Callback fired (on the main queue) when an AirPods mute gesture is detected.
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
        registerDarwinNotification(primaryNotification)

        // In debug mode, cast a wider net to help discover the right name / behaviour.
        if debugMode {
            for name in debugExtraNotifications {
                registerDarwinNotification(name)
            }
            registerDistributedNotifications()
        }

        isMonitoring = true
        log.info("Started monitoring. Listening for \(self.primaryNotification, privacy: .public)")
        return true
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        unregisterDarwinNotification(primaryNotification)
        if debugMode {
            for name in debugExtraNotifications {
                unregisterDarwinNotification(name)
            }
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDistributedCenter(),
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        isMonitoring = false
        log.info("Stopped monitoring")
    }

    // MARK: - Event handling

    /// Called for every raw notification. Decides whether it represents a mute gesture
    /// and, if so, forwards a single debounced event to `onMuteStateChanged`.
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
        // the AppDelegate just toggles the current mute state.
        DispatchQueue.main.async { [weak self] in
            self?.onMuteStateChanged?(.unknown)
        }
    }

    // MARK: - Darwin notifications

    private func registerDarwinNotification(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer else { return }
            let monitor = Unmanaged<AudioAccessoryMonitor>.fromOpaque(observer).takeUnretainedValue()
            let notificationName = name?.rawValue as String? ?? "unknown"
            monitor.handleNotification(notificationName)
        }

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            name as CFString,
            nil,
            .deliverImmediately
        )
        log.debug("Registered Darwin notification: \(name, privacy: .public)")
    }

    private func unregisterDarwinNotification(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
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
            monitor.handleNotification("Distributed:\(notificationName)")
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
