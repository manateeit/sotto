# Releasing Sotto

Everything in this document has to be run by a human with an Apple Developer account and a GitHub account with push access — none of it can be done headlessly by an agent. Do these steps in order.

## 1. One-time: get a Developer ID Application certificate

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) if you haven't (it's a paid account, distinct from a free Apple ID).
2. In Xcode: Settings → Accounts → your Apple ID → Manage Certificates → **+** → "Developer ID Application". Xcode creates the certificate and installs it in your login keychain.
   - No Xcode installed? Create the certificate at [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list), download it, and double-click to install into your keychain.
3. Confirm it's installed and find its exact name:
   ```bash
   security find-identity -v -p codesigning
   ```
   You want the line reading `"Developer ID Application: Your Name (TEAMID)"`.

You only need to do this once; the certificate is reused for every future release until it expires (5 years).

## 2. Sign and package a release build

`scripts/make-app.sh` defaults to `VERSION=0.0.1` (its dev/CI value). For an actual release, set `VERSION` explicitly — it flows into the app's `CFBundleShortVersionString`/`CFBundleVersion`, and `make-dmg.sh` reads it back out of the built app to name the DMG, so setting it once here keeps everything downstream (the DMG filename, the git tag, the GitHub release) in lockstep:

```bash
VERSION=0.1.0 bash scripts/make-app.sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/make-dmg.sh
```

Do these in order: set `VERSION` on the `make-app.sh` call → `make-app.sh` builds the app with that version baked into Info.plist → `make-dmg.sh` (no `VERSION` needed — it reads `CFBundleShortVersionString` from the app you just built) produces `dist/Sotto-0.1.0.dmg` → the git tag in step 4 must match that same version. If you skip setting `VERSION`, you'll get `dist/Sotto-0.0.1.dmg` and a mismatched tag.

`make-dmg.sh` re-signs `dist/Sotto.app` with your identity and `--options runtime` (hardened runtime — required for notarization) when `SIGN_IDENTITY` is set, then packages the signed app into `dist/Sotto-<version>.dmg`. Without `SIGN_IDENTITY`, it stays ad-hoc signed, which is fine for local testing but Gatekeeper will block it on other people's Macs.

## 3. Notarize

Apple has to scan and notarize the app before Gatekeeper will let anyone else run it without a security warning.

1. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com) (Sign-In and Security → App-Specific Passwords) — don't use your real Apple ID password.
2. Store credentials once so you don't have to pass them every time:
   ```bash
   xcrun notarytool store-credentials sotto-notary \
     --apple-id "you@example.com" \
     --team-id "TEAMID" \
     --password "the-app-specific-password"
   ```
3. Submit the signed DMG and wait for the result (usually a few minutes):
   ```bash
   xcrun notarytool submit dist/Sotto-<version>.dmg --keychain-profile sotto-notary --wait
   ```
   If it comes back `Invalid` instead of `Accepted`, get the details before re-signing:
   ```bash
   xcrun notarytool log <submission-id> --keychain-profile sotto-notary
   ```
4. Staple the notarization ticket to the DMG so it works offline (Gatekeeper otherwise phones Apple on first launch):
   ```bash
   xcrun stapler staple dist/Sotto-<version>.dmg
   ```
5. Sanity check:
   ```bash
   spctl -a -vv -t install dist/Sotto-<version>.dmg
   ```
   Expect `accepted` and `source=Notarized Developer ID`.

## 4. Publish the GitHub release

```bash
gh repo create manateeit/sotto --public --source=. --remote=origin --push   # first release only
git tag v0.1.0
git push origin v0.1.0
gh release create v0.1.0 dist/Sotto-0.1.0.dmg \
  --title "Sotto v0.1.0" \
  --notes "First public release."
```

Then update the Install section of `README.md` with the real download link (`gh release create` prints it, or find it under the repo's Releases tab).

## 5. Record the demo GIF

`README.md` references `docs/demo.gif`, a placeholder. Record a short (15–30s) screen capture of: pressing ⌥Space, speaking a sentence, watching the HUD, and seeing cleaned-up text land in a text field. QuickTime Player → File → New Screen Recording, then convert to GIF (e.g. `gifski` or the Screenshot app's built-in trimming + a converter) and save it to `docs/demo.gif`.

## Caveat: launch-at-login and app translocation

Sotto's launch-at-login (`SMAppService`) only works when the app runs from a stable location — in practice, `/Applications`. If a user runs Sotto straight out of a mounted DMG or a quarantined Downloads-folder copy, macOS's Gatekeeper path randomization ("app translocation") moves the executable to a hidden read-only location that changes on every launch, and `SMAppService` silently fails to re-register on the next boot. The DMG's `/Applications` symlink (built into `scripts/make-dmg.sh`) exists so the standard drag-to-Applications gesture avoids this — but nothing stops a user from running the app directly from the DMG. Consider surfacing a one-time check ("Sotto isn't running from Applications — launch-at-login won't work") if this trips people up in practice.
