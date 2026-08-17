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
    MikserApp.main()
}
