# Software Updates (Sparkle)

SimpleSpread uses [Sparkle 2](https://sparkle-project.org) for in-place
software updates, driven by GitHub Releases. When an update is found, Sparkle
downloads the signed DMG, verifies its EdDSA signature (and, on notarized
builds, the Apple code signature), replaces the running `.app` after it quits,
and relaunches it — one click, no manual drag.

## Moving parts

| Piece | Where |
|---|---|
| Updater UI | `Sources/SpreadsheetUI/SparkleUpdater.swift`; menu items in `App.swift` (`AppInfoCommands`) |
| Appcast feed | `appcast.xml` at the repo root, served at `https://raw.githubusercontent.com/baudehlo/SimpleSpread/main/appcast.xml` |
| Info.plist keys | injected by `scripts/embed-sparkle.sh` (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`) |
| Framework embedding | `scripts/embed-sparkle.sh` (copy + rpath) and `scripts/sign-sparkle.sh` (inside-out signing) |
| Release signing + publish | `.github/workflows/build.yml` → "Publish Sparkle appcast" step, using `scripts/update-appcast.sh` |

The app's `Check for Updates…` menu item and the `Automatically Check for
Updates` toggle live under the SimpleSpread app menu.

## One-time setup (required for updates to actually work)

Sparkle needs two things you provide once:

### 1. An EdDSA signing key

```bash
swift build                     # resolves Sparkle's tools
./scripts/setup-sparkle-key.sh  # generates the key, prints the public key
```

This stores the **private** key in your login Keychain and prints the
**public** key. Then:

```bash
# Private key → GitHub secret (sensitive, never commit):
"$(find .build/artifacts -name generate_keys -path '*bin*' | head -n1)" -x sparkle_private_key.txt
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key.txt
rm sparkle_private_key.txt

# Public key → GitHub repo variable (not sensitive):
gh variable set SPARKLE_PUBLIC_KEY --body '<SUPublicEDKey printed above>'
```

`SPARKLE_PUBLIC_KEY` is baked into each release build's Info.plist so the app
can verify updates; `SPARKLE_PRIVATE_KEY` signs each release's DMG in CI.

### 2. Apple Developer ID signing + notarization

Sparkle's in-place replacement only launches on **other** Macs if the new
build is Developer-ID-signed and notarized (Gatekeeper blocks an unsigned
replacement). Configure the existing release secrets: `APPLE_CERTIFICATE`,
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
`APPLE_PASSWORD`, `APPLE_TEAM_ID`. Until these exist the release DMG is
ad-hoc signed and self-update will be blocked by Gatekeeper on end-user
machines (the app still runs and can check for updates; the install step is
what needs the trusted signature).

## Cutting a release

Dispatch the **Build** workflow with a version (e.g. `1.2.0`). It:

1. runs tests, builds the arm64 release binary;
2. assembles `SimpleSpread.app`, embeds + signs `Sparkle.framework`, injects
   the Sparkle Info.plist keys;
3. signs + notarizes the app, builds the DMG, creates the GitHub Release;
4. if `SPARKLE_PRIVATE_KEY` is set: signs the DMG, inserts an `<item>` into
   `appcast.xml` pointing at the release's download URL, and commits
   `appcast.xml` back to `main`.

Existing installs then see the update within `SUScheduledCheckInterval`
(24h) or immediately via **Check for Updates…**.

## Local dev

`swift run` / `swift build` place `Sparkle.framework` next to the binary, so
the app launches, but unbundled/dev builds have no `SUPublicEDKey` and no
feed of their own — the updater is inert there by design. Use
`./scripts/build-app.sh` to produce an ad-hoc-signed `.app` with Sparkle
embedded for local testing of the bundle layout.
