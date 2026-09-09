## Installing

Mikser is signed ad-hoc rather than with an Apple Developer ID, so macOS
quarantines the download and refuses the first launch with a "Mikser is damaged
and can't be opened" alert. That is expected, and clearing the quarantine
attribute once is enough:

1. Unzip and move `Mikser.app` to `/Applications`.
2. Run:

```bash
xattr -d com.apple.quarantine /Applications/Mikser.app
```

3. Open it — a slider mark appears in the menu bar.

macOS asks for **Screen & System Audio Recording** permission the first time you
change an application's volume. Mikser needs it because Core Audio process taps
are how per-application volume works at all; captured audio is processed and sent
straight to the output device, never stored and never transmitted. The details are
in [SECURITY.md](https://github.com/erdmncdr/Mikser/blob/main/SECURITY.md).

Building from source avoids the quarantine step entirely.

---
