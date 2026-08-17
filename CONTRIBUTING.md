# Contributing to Mikser

Thank you for helping improve Mikser.

## Before opening a change

- Search existing issues and pull requests for related work.
- Keep changes focused and explain user-visible behavior.
- Do not include credentials, personal data, generated application bundles, or
  third-party proprietary assets.

## Build and verify

Mikser requires macOS 15 or later and a Swift 6 toolchain.

```bash
swift build -c release
```

Changes to the realtime path in `AppTap.swift` or `Equalizer.swift` must not allocate
memory, take locks, or call Objective-C from the IOProc. For audio-path changes, run
the end-to-end self-test described in the README with a steady 500 Hz tone.

## Pull requests

Describe what changed, why it changed, and how it was verified. By contributing, you
agree that your contribution is licensed under GPL-3.0-or-later.
