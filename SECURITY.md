# Security Policy

## Supported version

Mikser is in early development. Security fixes are applied to the latest revision on
the `main` branch.

## Trust model

Mikser asks for a powerful permission and updates itself, so it is worth being
explicit about what that means.

### Audio

Mikser holds macOS system audio recording permission — it has to, because process
taps are how per-application volume works at all. Captured audio is read in the
realtime IOProc, gain and equalization are applied, and it is written straight to
the output device. It is never written to disk and never sent anywhere: the app
makes no network requests of its own beyond the update check below, and the only
file it writes outside its preferences is a PNG when the `--dump-icons`
development flag is passed.

### Updates

Update integrity rests on an Ed25519 signature, not on the app's code signature.
Releases are signed ad-hoc rather than with an Apple Developer ID, so the
signature that matters is the one Sparkle checks:

- `SUPublicEDKey` in `Info.plist` is the trust anchor, and it is pinned in the app.
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are both enabled, so an
  unsigned or tampered archive is rejected before anything is unpacked.
- The feed is fetched over HTTPS from this repository's releases.

The corresponding private key exists only as the `SPARKLE_PRIVATE_KEY` repository
secret and is never checked into the tree. It is passed to `generate_appcast` on
standard input rather than as an argument, so it does not appear in a process
listing or in workflow logs.

Because that key is the single anchor for update trust, the release workflow pins
every action to a commit SHA rather than a moving tag, and passes values into shell
steps through `env:` rather than `${{ }}` interpolation.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
**Security → Report a vulnerability** form for this repository. Include reproduction
steps, affected macOS versions, and the potential impact. Reports will be reviewed
before details are made public.

For ordinary bugs that do not expose data or cross a security boundary, use the
public bug report template.
