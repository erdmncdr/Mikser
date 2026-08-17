//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreAudio
import Darwin
import Foundation

/// Verifies the tap chain end to end without touching the interface.
///
///     Mikser.app/Contents/MacOS/Mikser --selftest [target]
///
/// The target can be an application name, part of a bundle ID, an executable name,
/// or `pid:1234`. With no target, the first application currently playing is used.
///
/// Running the binary inside the app bundle means audio capture permission is granted
/// to the same code signature as the UI, so one approval covers both.
enum SelfTest {

    private struct Target {
        let name: String
        let processObjectIDs: [AudioObjectID]
    }

    static func run(bundleIDFilter: String?) {
        print("=== Mikser self-test ===\n")

        guard let output = AudioDevices.defaultOutputDevice() else {
            print("ERROR: no default output device found.")
            exit(1)
        }
        print("Output device: \(output.name) — \(output.outputChannels) channels, uid=\(output.uid)\n")

        let apps = AudioProcessMonitor.currentApps(favorites: [])
        print("--- Grouped applications (\(apps.count)) ---")
        for app in apps {
            print("  \(app.isPlaying ? "🔊" : "  ") \(app.name)  [\(app.id)]  processes: \(app.processObjectIDs)")
        }

        let processes = AudioProcessMonitor.currentProcesses()
        print("\n--- Raw process list (\(processes.count)) ---")
        for process in processes where process.isRunningOutput || process.bundleID?.isEmpty == false {
            let executable = executableName(pid: process.pid) ?? "?"
            print("  \(process.isRunningOutput ? "🔊" : "  ") obj=\(process.objectID) pid=\(process.pid) "
                  + "\(executable)  \(process.bundleID ?? "")")
        }
        print("")

        guard let target = resolveTarget(filter: bundleIDFilter, apps: apps, processes: processes) else {
            if let bundleIDFilter {
                print("No process with audio output matched '\(bundleIDFilter)'.")
            } else {
                print("Nothing is playing audio right now. Start something and try again.")
            }
            exit(2)
        }

        print("Target: \(target.name) — processes \(target.processObjectIDs)")
        print("Creating tap…")

        let tap = AppTap(appID: "selftest", displayName: target.name)
        tap.parameters.gain = 1.0

        do {
            try tap.start(processObjectIDs: target.processObjectIDs, outputDeviceUID: output.uid)
        } catch {
            print("\nERROR: \(error.localizedDescription)")
            if let caError = error as? CoreAudioError, caError.operation.contains("CreateProcessTap") {
                print("""

                This is usually a permission problem. Enable Mikser under
                System Settings → Privacy & Security → Screen & System Audio Recording.
                """)
            }
            exit(3)
        }

        if let format = tap.tapFormat {
            print("Tap format     : \(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) channels, "
                  + "\(format.mBitsPerChannel) bit, \(OSStatus(bitPattern: format.mFormatID).fourCharCode)")
        }
        // Equalizer coefficients are computed for this rate; the two can differ.
        if let rate = tap.deviceSampleRate {
            print("IOProc rate    : \(Int(rate)) Hz")
        }

        // Stage 1: is audio flowing at full gain?
        print("\n[1/4] Gain 100% — listening for 2.5 s")
        let fullGainPeak = measure(tap: tap, seconds: 2.5)

        // Stage 2: halve the gain; does the peak really halve?
        tap.parameters.gain = 0.5
        print("\n[2/4] Gain 50% — listening for 2.5 s")
        let halfGainPeak = measure(tap: tap, seconds: 2.5)

        // Stages 3-4: the equalizer. The 500 Hz band, first +12 dB then -12 dB.
        // For a meaningful measurement the source must be a steady tone near 500 Hz.
        let testBand = 4   // 500 Hz
        tap.parameters.gain = 1.0
        var gains = [Float](repeating: 0, count: EqualizerBands.count)

        gains[testBand] = 12
        tap.parameters.equalizer.update(gains: gains)
        tap.parameters.equalizer.isEnabled = true
        print("\n[3/4] Equalizer 500 Hz +12 dB — listening for 2.5 s")
        let boostedPeak = measure(tap: tap, seconds: 2.5)

        gains[testBand] = -12
        tap.parameters.equalizer.update(gains: gains)
        print("\n[4/4] Equalizer 500 Hz −12 dB — listening for 2.5 s")
        let cutPeak = measure(tap: tap, seconds: 2.5)

        tap.stop()

        // MARK: Result

        print("\n=== RESULT ===")
        guard fullGainPeak > 0.0001 else {
            print("The tap was created but no audio arrived.")
            print("Was \(target.name) actually playing during the test?")
            exit(4)
        }

        print(String(format: "Audio flow      : YES (peak %.4f)", fullGainPeak))

        let ratio = halfGainPeak / fullGainPeak
        let gainWorks = ratio > 0.35 && ratio < 0.65
        print(String(format: "Gain control    : %@ (ratio at 50%% is %.2f, expected ~0.50)",
                     gainWorks ? "WORKING" : "SUSPECT", ratio))

        // +12 dB is ×3.98, -12 dB is ×0.25. The source may not sit exactly on the band
        // centre, which lowers the skirt gain, so the bounds are deliberately wide.
        let boostRatio = boostedPeak / fullGainPeak
        let cutRatio = cutPeak / fullGainPeak
        let equalizerWorks = boostRatio > 1.8 && cutRatio < 0.6

        print(String(format: "Equalizer +12dB : ratio %.2f (expected ~3.98; lower if the tone is off centre)",
                     boostRatio))
        print(String(format: "Equalizer −12dB : ratio %.2f (expected ~0.25)", cutRatio))
        print("Equalizer       : \(equalizerWorks ? "WORKING" : "SUSPECT")")

        if gainWorks && equalizerWorks {
            print("\nPASS — the chain works:")
            print("application → process tap → aggregate device → IOProc (gain · balance · EQ) → speakers")
            exit(0)
        } else {
            print("\nAudio is flowing but the measurements are off.")
            print("The source must be a steady tone near 500 Hz; music gives no meaningful reading.")
            exit(5)
        }
    }

    // MARK: Helpers

    /// Readings during `settle` are discarded: measuring before the coefficient
    /// transition and the filter have settled catches the transient rather than the
    /// steady level.
    private static func measure(tap: AppTap, seconds: Double, settle: Double = 0.8) -> Float {
        var maximumPeak: Float = 0
        let steps = Int(seconds * 10)
        let settleSteps = Int(settle * 10)

        for step in 1...steps {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let peak = tap.parameters.consumePeak()
            let counted = step > settleSteps
            if counted { maximumPeak = max(maximumPeak, peak) }

            if step % 5 == 0 {
                let bars = Int((min(1, peak) * 40).rounded())
                let meter = String(repeating: "█", count: bars)
                    .padding(toLength: 40, withPad: "·", startingAt: 0)
                print(String(format: "  %.1fs |%@| %.4f%@",
                             Double(step) / 10, meter, peak, counted ? "" : "  (settling)"))
            }
        }
        return maximumPeak
    }

    private static func resolveTarget(
        filter: String?, apps: [AudioApp], processes: [AudioProcess]
    ) -> Target? {
        guard let filter else {
            // With no filter, take the first application that is playing.
            if let playing = apps.first(where: { $0.isPlaying }) {
                return Target(name: playing.name, processObjectIDs: playing.processObjectIDs)
            }
            if let playing = processes.first(where: { $0.isRunningOutput }) {
                return Target(name: executableName(pid: playing.pid) ?? "pid \(playing.pid)",
                              processObjectIDs: [playing.objectID])
            }
            return nil
        }

        // The pid:1234 form
        if filter.hasPrefix("pid:"), let pid = pid_t(filter.dropFirst(4)) {
            let matches = processes.filter { $0.pid == pid }
            guard !matches.isEmpty else { return nil }
            return Target(name: executableName(pid: pid) ?? "pid \(pid)",
                          processObjectIDs: matches.map(\.objectID).sorted())
        }

        // Search the grouped applications.
        if let app = apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(filter)
                || $0.id.localizedCaseInsensitiveContains(filter)
        }) {
            return Target(name: app.name, processObjectIDs: app.processObjectIDs)
        }

        // Search the raw process list — processes without a bundle, such as afplay,
        // land here.
        let matches = processes.filter { process in
            (process.bundleID?.localizedCaseInsensitiveContains(filter) ?? false)
                || (executableName(pid: process.pid)?.localizedCaseInsensitiveContains(filter) ?? false)
        }
        guard !matches.isEmpty else { return nil }
        return Target(name: filter, processObjectIDs: matches.map(\.objectID).sorted())
    }

    private static func executableName(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }
}
