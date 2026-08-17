//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Alert (sound effects) volume.
///
/// Core Audio has no equivalent for this — macOS keeps the alert volume separate
/// from ordinary device volume and only exposes it through the scripting
/// interface. This is the one place in the project that uses AppleScript.
///
/// Running a script takes 10-50 ms, so it cannot be called for every change while
/// a slider is being dragged. The UI tracks the value locally and only writes
/// here when the drag ends.
enum SystemAudio {

    static func alertVolume() -> Float? {
        guard let result = run("alert volume of (get volume settings)") else { return nil }
        return Float(result.int32Value) / 100
    }

    static func setAlertVolume(_ volume: Float) {
        let percent = Int((max(0, min(1, volume)) * 100).rounded())
        _ = run("set volume alert volume \(percent)")
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
