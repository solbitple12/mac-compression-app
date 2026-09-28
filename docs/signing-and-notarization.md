# Signing and notarizing Tamp

Tamp ships outside the Mac App Store. For Gatekeeper to open a downloaded copy
without warnings, Tamp has to be signed with a Developer ID certificate, sent to
Apple's notary service, and stapled with the ticket that comes back.
`scripts/release.sh` does all of that. Its dry run checks the build without a
certificate, and CI runs the dry run on every push.

Your certificate, passwords and keys stay in your own keychain. None of them go
into this repository or into CI.

## What you need once

1. **Apple Developer Program membership** for the team that will publish Tamp.
2. **A Developer ID Application certificate.** In Xcode, open Settings > Accounts,
   select your team, click Manage Certificates, then + > Developer ID Application.
   Only the team's Account Holder can create one. Check that it's installed:

   ```sh
   security find-identity -v -p codesigning
   ```

   Copy the full name it prints, for example
   `Developer ID Application: Jane Appleseed (AB12CD34EF)`. The part in
   parentheses is your Team ID.
3. **Notary credentials in your keychain.** Create an app-specific password at
   [account.apple.com](https://account.apple.com) (Sign-In and Security >
   App-Specific Passwords), then save it under a profile name:

   ```sh
   xcrun notarytool store-credentials tamp-notary \
     --apple-id you@example.com --team-id AB12CD34EF
   ```

   `notarytool` asks for the app-specific password and keeps it in the keychain.
   An App Store Connect API key works too: pass `--key`, `--key-id` and
   `--issuer` to `store-credentials` instead of the Apple ID.
4. **Tools:** Xcode 16 or later, and XcodeGen (`brew install xcodegen`).

The bundle ID is `io.github.solbitple12.Tamp`, set in `project.yml`. If you'd rather
use a domain you own, change it before the first public release. Changing it later
makes macOS treat the app as a different one, which resets permissions and settings.

## Dry run

```sh
scripts/release.sh --dry-run
```

This builds the helpers and a Release `Tamp.app`, signs it for this Mac only, and
fails if any of these would get the app rejected or break it on an older Mac:

- Tamp and each helper (7zz, bsdtar, zstd) has both arm64 and x86_64 code.
- Each one runs on macOS 14, the oldest version Tamp supports.
- Each one is signed with the hardened runtime.
- The app has no `get-task-allow` entitlement (a debugging entitlement that
  notarization refuses).
- `LSMinimumSystemVersion` is 14.0.
- Every bundled license file is present.
- `codesign --verify --deep --strict` passes.

The result is `build/release/Tamp.app` and `build/release/Tamp-<version>.zip`.
The dry run can't check the Developer ID signature or the secure timestamp,
because both need your certificate.

## Real release

```sh
export TAMP_SIGN_IDENTITY="Developer ID Application: Jane Appleseed (AB12CD34EF)"
export TAMP_TEAM_ID=AB12CD34EF
export TAMP_NOTARY_PROFILE=tamp-notary
scripts/release.sh
```

On top of the dry run's checks, the script:

1. Signs every helper and the app with your identity and a secure timestamp.
2. Confirms that each signature names Developer ID, your Team ID and a timestamp.
3. Zips the app and submits it with `xcrun notarytool submit --wait`. Apple usually
   answers within a few minutes.
4. If Apple rejects it, prints the notary log, which lists each problem by file.
5. Staples the ticket to the app (`xcrun stapler staple`), so it opens offline too.
6. Checks that Gatekeeper reports `source=Notarized Developer ID`.
7. Zips the stapled app again as `build/release/Tamp-<version>.zip`, which is the
   file to publish.

Set the version in `project.yml` (`MARKETING_VERSION`, and increase
`CURRENT_PROJECT_VERSION` for every build you publish).

## Checking a download on another Mac

Download the zip in a browser (so it gets the quarantine flag), unzip it, and open
Tamp. It should open with only the usual "downloaded from the internet" prompt. To
see what Gatekeeper decided:

```sh
spctl --assess --type execute -vv /Applications/Tamp.app
```

## When notarization fails

The notary log names the file and the reason. The common ones:

| Log says | Cause | Fix |
| --- | --- | --- |
| The binary is not signed | A helper was copied in without signing | Rebuild with `scripts/release.sh`; `scripts/bundle-helpers.sh` signs each helper |
| The executable does not have the hardened runtime enabled | A binary was signed without `--options runtime` | Same as above; the dry run catches this |
| The signature does not include a secure timestamp | Signed with `--timestamp=none` | Only the ad-hoc dry run does that; the real run uses `--timestamp` |
| The executable requests the com.apple.security.get-task-allow entitlement | A Debug build was submitted | Submit the Release build from `scripts/release.sh` |
| The signature of the binary is invalid | The app was changed after signing | Don't edit the bundle after the build; run the script again |

To see a past submission's log: `xcrun notarytool log <submission-id> --keychain-profile tamp-notary`.

## Signing in CI (later)

CI only runs the dry run. Signing in GitHub Actions would need the certificate
(as a .p12 with its password) and an App Store Connect API key stored as repository
secrets, plus a temporary keychain on the runner. That's worth setting up once
releases are regular. Until then, run the real release on your own Mac.
