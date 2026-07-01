//
//  AppDelegate.swift
//  PodsMute
//
//  Application delegate handling app lifecycle and service initialization.
//

import Cocoa

/// Main application delegate.
///
/// Responsibilities:
/// - Initialize and wire up all services
/// - Monitor audioaccessoryd Darwin notifications for AirPods mute events
/// - Toggle system mute when AirPods button is pressed
/// - Handle app lifecycle events
///
/// The key insight: audioaccessoryd emits Darwin notifications (com.apple.audioaccessoryd.MuteState)
/// when AirPods triggers a mute action. We listen for these native events.
/// Supports AirPods Max and AirPods Pro.
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services

    private var audioController: AudioMuteController!
    private var audioAccessoryMonitor: AudioAccessoryMonitor!
    private var statusBarController: StatusBarController!

    // Keep reference to BluetoothManager for device detection (status display)
    private var bluetoothManager: BluetoothManager!

    // Held for the app's lifetime to keep macOS App Nap from throttling our run loop.
    // Without this, this background (LSUIElement) app gets napped when idle and the
    // audioaccessoryd Darwin notification is delivered late or coalesced away — so a
    // stem press would sometimes not toggle the mic until much later.
    private var activityToken: NSObjectProtocol?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] Application launching...")

        // Opt out of App Nap so mute-gesture notifications are handled immediately.
        // (Allows idle system sleep — we don't need to keep the whole Mac awake.)
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Listening for AirPods mute-gesture notifications")

        // Initialize services
        setupServices()

        // Setup audioaccessoryd notification monitoring
        setupAudioAccessoryMonitoring()

        print("[AppDelegate] Application ready")
        print("[AppDelegate] Press your AirPods button to toggle mute")
        print("[AppDelegate] Listening for audioaccessoryd mute state notifications...")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] Application terminating...")

        // Restore mic to unmuted state if it was muted by this app
        if audioController.isMuted {
            print("[AppDelegate] Restoring microphone to unmuted state...")
            audioController.setMute(false)
        }

        audioAccessoryMonitor?.stopMonitoring()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Setup

    private func setupServices() {
        // Create audio controller first (no dependencies)
        audioController = AudioMuteController()

        // Create Bluetooth manager (for device status display)
        bluetoothManager = BluetoothManager()

        // Create audio accessory monitor (for AirPods crown button detection)
        audioAccessoryMonitor = AudioAccessoryMonitor()

        // Create status bar controller
        statusBarController = StatusBarController(
            audioController: audioController,
            bluetoothManager: bluetoothManager
        )

        // Check for paired AirPods (for status display)
        checkForAirPods()
    }

    private func setupAudioAccessoryMonitoring() {
        // Diagnostic mode: run with `PODSMUTE_DEBUG=1` to also watch speculative
        // notification names and log every notification to Console.app. Use this to
        // confirm which notification your macOS version posts when you press the stem.
        audioAccessoryMonitor.debugMode = ProcessInfo.processInfo.environment["PODSMUTE_DEBUG"] != nil

        // Set up callback for mute state changes from AirPods.
        // NOTE: this runs on the monitor's background queue. Do the actual mute here
        // (off-main, so an App-Napped main run loop can't delay it), then hop to main
        // only for the menu-bar UI.
        audioAccessoryMonitor.onMuteStateChanged = { [weak self] _ in
            guard let self = self else { return }

            print("[AppDelegate] AirPods mute gesture detected")

            // Toggle system mute immediately (thread-safe, direct Core Audio).
            let muted = self.audioController.toggleMuteThreadSafe()

            DispatchQueue.main.async {
                self.statusBarController.updateIcon()
                if let muted = muted {
                    self.statusBarController.showMutePopover(isMuted: muted)
                }
            }
        }

        // Debug: log all notifications
        audioAccessoryMonitor.onNotification = { notification in
            print("[AppDelegate] Audio accessory notification: \(notification)")
        }

        // Start monitoring
        let success = audioAccessoryMonitor.startMonitoring()

        if success {
            print("[AppDelegate] Audio accessory monitoring started successfully")
        } else {
            print("[AppDelegate] WARNING: Failed to start audio accessory monitoring")
        }
    }

    private func checkForAirPods() {
        let devices = bluetoothManager.pairedDevices()

        if devices.isEmpty {
            print("[AppDelegate] No paired AirPods found")
            print("[AppDelegate] Please pair your AirPods Max or AirPods Pro and try again")
        } else {
            print("[AppDelegate] Found \(devices.count) paired AirPods device(s):")
            for device in devices {
                print("  - \(device.name) (\(device.id))")
            }
        }
    }
}
