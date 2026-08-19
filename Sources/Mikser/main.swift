//  Mikser — per-app audio control for macOS
//  Copyright (C) 2026 Mikser Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

// Catch development flags before bringing up the UI.
if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    let filter = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : nil
    SelfTest.run(bundleIDFilter: filter)
} else if CommandLine.arguments.contains("--preview") {
    MainActor.assumeIsolated { PreviewRunner.run() }
} else if let index = CommandLine.arguments.firstIndex(of: "--dump-icons") {
    let directory = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "."
    MikserIcon.dumpVariants(to: directory)
    exit(0)
} else {
    exitIfAnotherInstanceIsRunning()
    MikserApp.main()
}

/// Quits immediately when another copy of Mikser is already running.
///
/// Nothing stops a second copy from being launched — a build sitting in a checkout
/// and an installed one in /Applications share a bundle identifier — and both would
/// then place an icon in the menu bar and create process taps for the same
/// applications. Two taps on one process with `.mutedWhenTapped` means the second
/// one captures silence, which reads as "the audio just stopped working".
///
/// The newcomer is the one that exits, leaving whichever instance the user already
/// had running untouched.
func exitIfAnotherInstanceIsRunning() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }

    let ownPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ownPID }
    guard let existing = others.first else { return }

    let location = existing.bundleURL?.path ?? "unknown location"
    FileHandle.standardError.write(Data(
        "Mikser is already running (pid \(existing.processIdentifier), \(location)). Quitting this copy.\n".utf8
    ))
    exit(0)
}
