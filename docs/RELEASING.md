# Releasing

A release is a DMG holding `AutomationAgent.app` (with the runner embedded at
`Contents/Library/LoginItems/AutomationAgentRunner.app`), signed with a Developer ID
Application certificate, notarized by Apple and stapled, so it opens on any Mac without
Gatekeeper warnings.

- `scripts/release.sh` does the whole job on a Mac: archive, check, DMG, notarize, staple.
- `.github/workflows/release.yml` runs it on GitHub when you push a `v*` tag, and publishes
  a GitHub Release with the DMG.
- `Config/Release.xcconfig` holds the Release signing settings: Developer ID, manual
  signing, hardened runtime, secure timestamp. Debug keeps automatic "Apple Development"
  signing from `Config/Base.xcconfig`, so local work is unchanged.

## What you need

1. **A paid Apple Developer Program membership.** Developer ID certificates and
   notarization are not available to free personal teams. Your team id is under
   Membership details at <https://developer.apple.com/account>.
2. **A Developer ID Application certificate.** Only the Account Holder can create one.
   In Xcode: Settings > Accounts > your team > Manage Certificates > + > Developer ID
   Application. Or at <https://developer.apple.com/account/resources/certificates> with a
   certificate signing request from Keychain Access. Check it is installed:
   `security find-identity -v -p codesigning` lists
   `"Developer ID Application: Your Name (TEAMID)"`.
3. **Notarization credentials**, one of:
   - **An App Store Connect API key** (what CI uses). In App Store Connect > Users and
     Access > Integrations > App Store Connect API, create a Team key with the
     **Developer** role. Note the key id and the issuer id, and download the
     `AuthKey_<KEYID>.p8` file (you can download it only once).
   - **A keychain profile**, for your own Mac:
     `xcrun notarytool store-credentials automation-agent --apple-id you@example.com --team-id TEAMID`
     (it asks for an app-specific password from <https://account.apple.com>), or with
     `--key`, `--key-id` and `--issuer` for an API key.

## Building a release on your Mac

```bash
# Team id: Config/Local.xcconfig, or DEVELOPMENT_TEAM=TEAMID in the environment.
export NOTARY_KEYCHAIN_PROFILE=automation-agent
# or: export NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… NOTARY_KEY_PATH=~/keys/AuthKey_….p8
make release                    # scripts/release.sh
scripts/release.sh --version 0.2.0 --build-number 7
```

The DMG lands in `build/release/AutomationAgent-<version>.dmg` and the script prints its
path. Without `--version` it uses `MARKETING_VERSION` from `Config/Base.xcconfig`.

`make release-local` (`scripts/release.sh --skip-notarize`) builds and signs the same
DMG without notarizing it: good for checking signing on your own Mac, but other Macs will
see an "unnotarized" warning. `scripts/release.sh --unsigned` builds without any signing,
as CI does without secrets.

The script fails early, with the fix, when the team id, the certificate or the
notarization credentials are missing. Along the way it:

1. generates the project and runs `xcodebuild archive -configuration Release`;
2. copies the app out of the archive and runs `scripts/verify-bundle.sh` on it;
3. checks `codesign --verify --deep --strict`, and that the app and the runner are each
   signed with Developer ID, with the hardened runtime, a secure timestamp, no
   `get-task-allow`, and the same team id (the runner refuses XPC clients from another
   team);
4. makes a compressed DMG (`hdiutil create -format UDZO`) with an `/Applications` link,
   and signs it;
5. submits it with `xcrun notarytool submit --wait`, prints Apple's log if it is not
   accepted, then `xcrun stapler staple`s it and checks it with `spctl`.

Signing is inside out and never uses `--deep`: Xcode signs the runner target, then the
app target's embed phase (`codeSign: true` in `project.yml`) re-signs the copy inside
the app, and the app is signed last.

## Publishing from GitHub Actions

### Secrets

Add these under the repository's Settings > Secrets and variables > Actions > New
repository secret:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | The Developer ID Application certificate with its private key, as a base64 `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | The password you gave the `.p12` |
| `APPLE_TEAM_ID` | Your 10-character team id |
| `NOTARY_KEY_ID` | The App Store Connect API key id |
| `NOTARY_ISSUER_ID` | The API key's issuer id |
| `NOTARY_KEY_P8_BASE64` | The `AuthKey_<KEYID>.p8` file, base64 |

To make the `.p12`: in Keychain Access, under My Certificates, expand
"Developer ID Application: …", select the certificate (with its key), File > Export
Items…, save as `.p12` with a strong password. Then:

```bash
base64 -i DeveloperID.p12 | pbcopy        # paste as DEVELOPER_ID_CERT_P12_BASE64
base64 -i AuthKey_ABC123XYZ.p8 | pbcopy   # paste as NOTARY_KEY_P8_BASE64
```

Delete the exported `.p12` afterwards. With the `gh` CLI:
`base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12_BASE64`.

### What the workflow does

It runs on a pushed `v*` tag and on demand (Actions > Release > Run workflow, with an
optional version).

- **All six secrets set:** it imports the certificate into a temporary keychain, writes
  the API key to a temporary file, runs `scripts/release.sh`, uploads the DMG as a
  workflow artifact and, for a tag, creates the GitHub Release (notes generated from the
  commits; a tag with a `-`, like `v0.2.0-beta.1`, becomes a pre-release). The keychain
  and key file are deleted at the end, even when a step fails.
- **Any secret missing:** it builds an unsigned DMG, uploads it as a workflow artifact,
  says in the job summary that it is unsigned and which secrets are missing, and
  finishes successfully. No GitHub Release is created.

The version is the tag without its leading `v` (`v0.2.0` → `0.2.0`); the build number is
the workflow run number.

### Cutting a release

```bash
git switch main && git pull
git tag v0.2.0
git push origin v0.2.0
```

Watch the run under Actions > Release; notarization usually takes a few minutes. Consider
bumping `MARKETING_VERSION` in `Config/Base.xcconfig` to match, so local builds report
the same version.

## What users see on first launch

1. **Gatekeeper.** Opening the DMG and dragging the app to Applications works without a
   warning; the first launch shows the usual "downloaded from the Internet" confirmation.
   An unsigned or unnotarized build is blocked instead; such builds are for testing.
2. **Login Items approval.** Registering the runner (Runner screen > Register) adds
   "Automation Agent Runner" to System Settings > General > Login Items, where macOS may
   ask the user to allow it.
3. **Accessibility and Automation.** Automations that press keys or read selections need
   Accessibility access for the runner (System Settings > Privacy & Security >
   Accessibility); scripts that control other apps trigger the per-app Automation prompt
   the first time. Both are tied to the signature, so they survive updates signed by the
   same team.

## Troubleshooting

- **Notarization rejected.** The script prints the log; fetch it again with
  `xcrun notarytool log <submission-id> --keychain-profile automation-agent` (or `--key`,
  `--key-id`, `--issuer`). `xcrun notarytool history` lists past submissions.
- **"The executable does not have the hardened runtime enabled."** A target was built
  without `ENABLE_HARDENED_RUNTIME = YES`, or with an xcconfig other than
  `Config/Release.xcconfig`. Check `project.yml`'s `configFiles` and that nothing in
  `Config/Local.xcconfig` overrides signing. `codesign -dvv <app>` should show
  `flags=0x10000(runtime)` for both the app and the runner.
- **"The signature does not include a secure timestamp."** `OTHER_CODE_SIGN_FLAGS` lost
  `--timestamp`, or the timestamp server was unreachable; build again.
- **"The binary is not signed with a valid Developer ID certificate."** The archive was
  signed with Apple Development, usually because `DEVELOPMENT_TEAM` is not the team that
  owns the Developer ID certificate, or the certificate's private key is missing.
- **Nested code signing errors** ("code object is not signed at all … In subcomponent",
  "a sealed resource is missing or invalid"). Something changed the bundle after signing,
  or the runner was not re-signed when embedded. Never fix this with `codesign --deep`;
  run `make clean` and build again, and check that the runner dependency in `project.yml`
  still has `codeSign: true`. `codesign --verify --deep --strict --verbose=2 <app>` names
  the failing part.
- **`errSecInternalComponent` or "unable to build chain to self-signed root" in CI.** The
  keychain is locked or the certificate chain is incomplete: export the `.p12` again from
  Keychain Access with the certificate and its private key, and make sure the Developer
  ID intermediate certificate (G2) is installed.
- **The app cannot talk to the runner (XPC connection refused).** The runner only accepts
  clients signed as `dev.cldixon.AutomationAgent` by its own team. A runner left
  registered from a Debug build (Apple Development) or another team's build refuses the
  release app, and the reverse. Unregister the old runner from the build that registered
  it (or `launchctl bootout gui/$(id -u)/dev.cldixon.AutomationAgent.Runner`), delete
  stale copies of the app, then register again from the release. `release.sh` checks that
  the app and the runner it builds share a team id.
- **`hdiutil: create failed - Resource busy`.** The script retries; if it keeps failing,
  eject leftover "Automation Agent" volumes and run it again.
