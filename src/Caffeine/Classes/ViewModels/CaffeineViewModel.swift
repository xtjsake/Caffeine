//
//  CaffeineViewModel.swift
//  Caffeine
//
//  Created by Dominic Rodemer on 11.11.25.
//

import ApplicationServices
import Combine
import IOKit.ps
import SwiftUI

/// Main view model for the Caffeine application
@MainActor
class CaffeineViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var isActive = false
    @Published var timeRemaining: TimeInterval?
    @Published var showPreferences = false

    // MARK: - Private Properties

    private var timeoutTimer: Timer?
    private var displayTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var powerSourceRunLoopSource: CFRunLoopSource?

    /// Deactivate Caffeine when the battery drops below this percentage
    private static let lowBatteryThreshold = 50

    // MARK: - Initialization

    init() {
        // Explicitly ensure we start inactive
        self.isActive = false
        self.timeRemaining = nil

        self.setupObservers()

        // Check if we should activate at launch
        if UserDefaults.standard.bool(forKey: PreferenceKeys.activateAtLaunch) {
            self.activate()
        }

        // Apply the "keep active on AC power" policy at launch
        self.applyPowerPolicy()

        // Show preferences on first launch
        if !UserDefaults.standard.bool(forKey: PreferenceKeys.suppressLaunchMessage) {
            self.showPreferences = true
        }
    }

    deinit {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    // MARK: - Public Methods

    /// Toggles the active state
    func toggleActive() {
        if self.isActive {
            self.deactivate()
        } else {
            self.activate()
        }
    }

    /// Activates Caffeine with optional timeout
    func activate(withTimeout timeout: TimeInterval? = nil) {
        // Use default duration if no timeout specified
        let duration: TimeInterval?
        if let timeout {
            duration = timeout > 0 ? timeout : nil
        } else {
            let defaultMinutes = UserDefaults.standard.integer(forKey: PreferenceKeys.defaultDuration)
            duration = defaultMinutes > 0 ? TimeInterval(defaultMinutes * 60) : nil
        }

        // Cancel existing timers
        self.cancelTimers()

        // Set up timeout timer if duration specified
        if let duration {
            self.timeRemaining = duration

            self.timeoutTimer = Timer.scheduledTimer(
                withTimeInterval: duration,
                repeats: false
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.deactivate()
                }
            }

            // Update display every second
            self.displayTimer = Timer.scheduledTimer(
                withTimeInterval: 1.0,
                repeats: true
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard
                        let self,
                        let timeoutTimer = self.timeoutTimer else
                    {
                        self?.displayTimer?.invalidate()
                        return
                    }

                    self.timeRemaining = max(0, timeoutTimer.fireDate.timeIntervalSinceNow)
                    if self.timeRemaining ?? 0 <= 0 {
                        self.displayTimer?.invalidate()
                        self.displayTimer = nil
                    }
                }
            }
        } else {
            self.timeRemaining = nil
        }

        self.isActive = true
        SleepPreventionManager.shared.preventSleep()

        if UserDefaults.standard.bool(forKey: PreferenceKeys.keepAppsActive) {
            ActivitySimulator.shared.startMonitoring()
        }
    }

    /// Deactivates Caffeine
    func deactivate() {
        self.cancelTimers()
        self.timeRemaining = nil
        self.isActive = false
        SleepPreventionManager.shared.allowSleep()
        ActivitySimulator.shared.stopMonitoring()
    }

    /// Updates activity simulation based on preference
    func updateActivitySimulation(enabled: Bool) {
        if enabled {
            // Trigger the Accessibility permission prompt by posting a no-op event
            // This prompts for "Events" permission which CGEvent.post requires
            ActivitySimulator.shared.requestPermission()
        }

        if enabled, self.isActive {
            ActivitySimulator.shared.startMonitoring()
        } else {
            ActivitySimulator.shared.stopMonitoring()
        }
    }

    /// Updates the keep-active-on-AC-power behavior based on preference
    func updateKeepActiveOnACPower(enabled: Bool) {
        guard enabled else { return }
        self.applyPowerPolicy()
    }

    /// Returns a formatted string for the remaining time
    func formattedTimeRemaining() -> String? {
        // Only return a status if actually active
        guard self.isActive else {
            return nil
        }

        // If there's time remaining, format it
        if let remaining = timeRemaining, remaining > 0 {
            let seconds = Int(remaining)

            if seconds >= 3600 {
                let hours = seconds / 3600
                let minutes = (seconds % 3600) / 60
                return String(format: "%02d:%02d", hours, minutes)
            } else if seconds > 60 {
                let minutes = seconds / 60
                let format = String(localized: "%d minutes", comment: "Time remaining in minutes")
                return String.localizedStringWithFormat(format, minutes)
            } else {
                let format = String(localized: "%d seconds", comment: "Time remaining in seconds")
                return String.localizedStringWithFormat(format, seconds)
            }
        }

        // Active with no timer (indefinite)
        return String(localized: "Caffeine is active")
    }

    // MARK: - Private Methods

    private func setupObservers() {
        // Observe workspace sleep notification
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    if UserDefaults.standard.bool(forKey: PreferenceKeys.deactivateOnManualSleep) {
                        self?.deactivate()
                    }
                }
            }
            .store(in: &self.cancellables)

        // Run-loop timers don't advance during sleep, so on wake check whether
        // the activation period elapsed and deactivate if so
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, let timeoutTimer = self.timeoutTimer else { return }
                    if timeoutTimer.fireDate.timeIntervalSinceNow <= 0 {
                        self.deactivate()
                    }
                }
            }
            .store(in: &self.cancellables)

        // React to power source changes (AC adapter connected / disconnected)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyPowerPolicy()
                }
            }
            .store(in: &self.cancellables)

        // React to power source updates (covers battery level changes,
        // which do not produce a process power state change)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let viewModel = Unmanaged<CaffeineViewModel>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                viewModel.applyPowerPolicy()
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            self.powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    /// Activates when the Mac is connected to power, deactivates when the
    /// battery drops below the low-battery threshold,
    /// if the "keep active on AC power" preference is enabled
    private func applyPowerPolicy() {
        guard UserDefaults.standard.bool(forKey: PreferenceKeys.keepActiveOnACPower) else { return }

        if Self.isExternalPowerConnected() {
            if !self.isActive {
                self.activate()
            }
        } else if self.isActive, let level = Self.batteryLevel(), level < Self.lowBatteryThreshold {
            self.deactivate()
        }
    }

    /// Returns the current battery charge percentage (0-100), or nil if the
    /// battery level is unavailable.
    private static func batteryLevel() -> Int? {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue as String,
                let level = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }

            return level
        }

        return nil
    }

    /// Returns whether the Mac is connected to an external power source.
    /// Desktops without a battery are treated as always connected.
    private static func isExternalPowerConnected() -> Bool {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return true }

        var hasBattery = false

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }

            if state == kIOPSACPowerValue as String { return true }
            if state == kIOPSBatteryPowerValue as String { hasBattery = true }
        }

        return !hasBattery
    }

    private func cancelTimers() {
        self.timeoutTimer?.invalidate()
        self.timeoutTimer = nil
        self.displayTimer?.invalidate()
        self.displayTimer = nil
    }
}

// MARK: - Preference Keys

enum PreferenceKeys {
    static let activateAtLaunch = "CAActivateAtLaunch"
    static let defaultDuration = "CADefaultDuration"
    static let suppressLaunchMessage = "CASuppressLaunchMessage"
    static let deactivateOnManualSleep = "CADeactivateOnManualSleep"
    static let keepAppsActive = "CAKeepAppsActive"
    static let keepActiveOnACPower = "CAKeepActiveOnACPower"
}
