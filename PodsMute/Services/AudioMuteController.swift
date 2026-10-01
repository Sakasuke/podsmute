//
//  AudioMuteController.swift
//  PodsMute
//
//  Controls system-wide microphone mute state using Core Audio.
//
//  Fork change (Airpods-mute): mute is applied to EVERY real input device (built-in
//  mic, AirPods, USB mics, …), not just the current default input. Muting only the
//  default device fails whenever the app you're talking into captures from a different
//  device, or when the default input switches (e.g. AirPods going in/out of the call's
//  hands-free mode). Virtual/loopback devices (e.g. "Microsoft Teams Audio") are skipped.
//
//  `isMuted` is our own logical intent — the single source of truth for the badge — and
//  it is re-asserted onto the device set whenever the audio devices change.
//
//  v1.0.1: re-asserting must never feed itself. In some coreaudiod states (seen on
//  macOS 27) every mute write makes coreaudiod re-pick and re-announce the default
//  input, which fired our listener, which wrote again — 2–3 writes/s all night, keeping
//  the Mac awake and hot. Now we only write a device whose mute differs from the
//  target, coalesce notification bursts, and back off if a device keeps reverting.
//

import Foundation
import CoreAudio
import Combine

/// Controller for managing system-wide microphone mute state.
final class AudioMuteController: ObservableObject {

    // MARK: - Published Properties

    /// Logical mute state controlled by this app (source of truth for the UI).
    @Published private(set) var isMuted: Bool = false

    /// Name of the current default input device (for display only).
    @Published private(set) var inputDeviceName: String = "Unknown"

    /// Whether at least one real input device supports muting.
    @Published private(set) var supportsMute: Bool = false

    // MARK: - Private Properties

    private var deviceListChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    /// Serial queue for Core Audio change notifications. The re-assert state below is
    /// only touched on this queue.
    private let listenerQueue = DispatchQueue(label: "PodsMute.AudioMuteController.listeners")
    private var pendingReassert: DispatchWorkItem?
    /// When automatic re-asserts last had to write a device (for the back-off below).
    private var recentReassertWrites: [Date] = []
    private var reassertSuspendedUntil = Date.distantPast

    /// Notifications arrive in bursts (AirPods connecting fires several); handle the
    /// burst once it settles.
    private static let reassertDelay: TimeInterval = 0.3
    /// If automatic re-asserts had to write `reassertWriteLimit` times within
    /// `reassertWindow`, some device is fighting us — pause for `reassertBackoff`.
    private static let reassertWriteLimit = 5
    private static let reassertWindow: TimeInterval = 10
    private static let reassertBackoff: TimeInterval = 30

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)

    // MARK: - Initialization

    init() {
        refreshDefaultDeviceDisplay()
        setupChangeListeners()
    }

    deinit {
        removeListeners()
    }

    // MARK: - Public Methods

    /// Toggle mute across all input devices.
    func toggleMute() {
        setMute(!isMuted)
    }

    /// Thread-safe toggle for use off the main thread (e.g. from the notification
    /// dispatch queue) — the actual Core Audio calls are synchronous and safe on any
    /// thread, so the mic mutes the instant you press even while the app is App-Napped.
    /// - Returns: the new muted state, or `nil` if no input device could be muted.
    @discardableResult
    func toggleMuteThreadSafe() -> Bool? {
        let target = !isMuted
        let applied = applyMuteToAllInputs(target).controlled
        guard applied > 0 else {
            print("[AudioMuteController] toggleMuteThreadSafe: no controllable input devices")
            return nil
        }
        publishMuted(target)
        return target
    }

    /// Set mute across all input devices.
    func setMute(_ muted: Bool) {
        let applied = applyMuteToAllInputs(muted).controlled
        print("[AudioMuteController] Applied mute=\(muted) to \(applied) input device(s)")
        publishMuted(muted)
    }

    /// Kept for API compatibility with the UI; re-asserts our state onto the devices.
    func refreshMuteState() {
        applyMuteToAllInputs(isMuted)
    }

    // MARK: - Core: mute every real input device

    /// Apply `muted` to every real (non-virtual) input device that has a settable mute
    /// control. Devices already in that state are left alone — writing an unchanged
    /// value is what let the re-assert loop feed itself.
    /// - Returns: `controlled` = devices now in the target state, `written` = devices
    ///   we actually had to write.
    @discardableResult
    private func applyMuteToAllInputs(_ muted: Bool) -> (controlled: Int, written: Int) {
        var addr = AudioMuteController.muteAddress
        let target: UInt32 = muted ? 1 : 0
        var controlled = 0
        var written = 0
        for device in realInputDeviceIDs() {
            if deviceMuteValue(device) == target {
                controlled += 1
                continue
            }
            var value = target
            let result = AudioObjectSetPropertyData(
                device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            if result == noErr {
                controlled += 1
                written += 1
            }
        }
        return (controlled, written)
    }

    private func deviceMuteValue(_ device: AudioObjectID) -> UInt32? {
        var addr = AudioMuteController.muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// All input devices we should control: has an input stream, has a settable mute
    /// property, and is not a virtual/loopback device.
    private func realInputDeviceIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.filter { deviceHasInputStream($0) && deviceMuteIsSettable($0) && !deviceIsVirtual($0) }
    }

    private func deviceHasInputStream(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private func deviceMuteIsSettable(_ device: AudioObjectID) -> Bool {
        var addr = AudioMuteController.muteAddress
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func deviceIsVirtual(_ device: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
    }

    // MARK: - State plumbing

    private func publishMuted(_ muted: Bool) {
        if Thread.isMainThread {
            isMuted = muted
        } else {
            DispatchQueue.main.async { self.isMuted = muted }
        }
    }

    private func refreshDefaultDeviceDisplay() {
        let devices = realInputDeviceIDs()
        let hasControllable = !devices.isEmpty

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        let name = device != kAudioObjectUnknown ? deviceName(device) : "No Input Device"

        DispatchQueue.main.async {
            self.inputDeviceName = name
            self.supportsMute = hasControllable
        }
    }

    private func deviceName(_ device: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cf) == noErr,
              let name = cf?.takeRetainedValue() else { return "Unknown Device" }
        return name as String
    }

    // MARK: - Change listeners

    private func setupChangeListeners() {
        // When the set of audio devices changes (AirPods connect, mic plugged in, or the
        // call switches AirPods into hands-free mode), re-assert our mute state onto the
        // new device set so nothing comes back unmuted behind our back.
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        deviceListChangeListenerBlock = { [weak self] _, _ in
            self?.scheduleReassert()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddr, listenerQueue, deviceListChangeListenerBlock!)

        // Default input changes: refresh the displayed name and re-assert mute.
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        defaultDeviceChangeListenerBlock = { [weak self] _, _ in
            self?.scheduleReassert()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, listenerQueue, defaultDeviceChangeListenerBlock!)
    }

    /// Runs on `listenerQueue`. Collapses a burst of notifications into one re-assert.
    private func scheduleReassert() {
        pendingReassert?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reassertAfterDeviceChange() }
        pendingReassert = work
        listenerQueue.asyncAfter(deadline: .now() + AudioMuteController.reassertDelay, execute: work)
    }

    /// Runs on `listenerQueue`.
    private func reassertAfterDeviceChange() {
        refreshDefaultDeviceDisplay()

        let now = Date()
        guard now >= reassertSuspendedUntil else { return }
        guard applyMuteToAllInputs(isMuted).written > 0 else { return }

        recentReassertWrites = recentReassertWrites.filter {
            now.timeIntervalSince($0) < AudioMuteController.reassertWindow
        } + [now]
        guard recentReassertWrites.count >= AudioMuteController.reassertWriteLimit else { return }

        // A device keeps reverting (or our writes keep re-triggering coreaudiod): stop
        // chasing it, then try once more so a device that arrived meanwhile still gets
        // our state.
        recentReassertWrites.removeAll()
        reassertSuspendedUntil = now.addingTimeInterval(AudioMuteController.reassertBackoff)
        print("[AudioMuteController] Mute keeps being reverted; pausing automatic re-assert for \(Int(AudioMuteController.reassertBackoff)) s")
        listenerQueue.asyncAfter(deadline: .now() + AudioMuteController.reassertBackoff) { [weak self] in
            self?.scheduleReassert()
        }
    }

    private func removeListeners() {
        if let block = deviceListChangeListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block)
            deviceListChangeListenerBlock = nil
        }
        if let block = defaultDeviceChangeListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block)
            defaultDeviceChangeListenerBlock = nil
        }
    }
}
