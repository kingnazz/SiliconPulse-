# Releasing

Releases are built and published by `.github/workflows/release.yml`.

1. Set the new version in `VERSION`, for example `1.1.0`.
2. Add a `## 1.1.0 — <date>` section to `CHANGELOG.md`; it becomes the release notes.
3. Merge to `main`. The workflow builds a universal (Apple Silicon + Intel) app, packages `SiliconPulse.dmg` and `SiliconPulse.zip` with `SHA256SUMS.txt`, smoke-tests the packaged app, and publishes GitHub release `v1.1.0`.

Every pull request runs the same packaging as a dry run and uploads the DMG as an artifact.

## Download links

Asset names carry no version, so these always point at the newest release:

- `https://github.com/kingnazz/SiliconPulse-/releases/latest/download/SiliconPulse.dmg`
- `https://github.com/kingnazz/SiliconPulse-/releases/latest/download/SiliconPulse.zip`
- `https://github.com/kingnazz/SiliconPulse-/releases/latest` (the release page and notes)

## Website

`site/` is the website, published to https://kingnazz.github.io/SiliconPulse-/ by `.github/workflows/pages.yml` on every push to `main`. The workflow adds `docs/screenshots/` and the app icon, so new screenshots appear on the site automatically. Its download buttons use the stable link above, so a new release needs no site change.

## Signing and notarization

Without signing secrets, the release is **ad-hoc signed**. macOS then blocks the first launch of a downloaded copy until the user clicks **Open Anyway** in System Settings › Privacy & Security; the release notes say so automatically.

For a download that opens normally, add these repository secrets (Settings › Secrets and variables › Actions). They need an Apple Developer Program membership.

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Your *Developer ID Application* certificate and private key, exported from Keychain Access as .p12, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you gave the .p12 export |
| `MACOS_SIGN_IDENTITY` | The identity name, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID` | Your Apple ID email |
| `NOTARY_TEAM_ID` | Your 10-character Team ID |
| `NOTARY_PASSWORD` | An app-specific password from appleid.apple.com |

With these set, the app and the DMG are signed with the hardened runtime, notarized with `notarytool`, and stapled. The release notes then say the build is notarized.

To re-publish an existing version (for example, after adding the secrets), delete its GitHub release and tag, then re-run the workflow on `main`.

## Local packaging

```bash
scripts/package-release.sh      # build/release/SiliconPulse.dmg, .zip, SHA256SUMS.txt
SIGN_IDENTITY="Developer ID Application: …" NOTARY_APPLE_ID=… NOTARY_TEAM_ID=… NOTARY_PASSWORD=… scripts/package-release.sh
```
