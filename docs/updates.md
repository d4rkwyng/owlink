# Updates (Sparkle 2): what is built, what is decided, what waits for release

Status: **on in release builds; nothing published yet.** Every build carries
Owlink's feed URL (`https://owlink.app/appcast.xml`) and EdDSA public key,
with automatic checks on. A release build (`Scripts/bundle-app.sh
--release`) loads Sparkle after the first frame, checks about once a day
and always asks before installing; Owlink › Check for Updates… checks now,
and Settings › General › Automatically check for updates turns the daily
check off. A check build (the default of bundle-app.sh) has no
Sparkle.framework and never loads it, sends nothing, and shows Check for
Updates… and the Settings checkbox disabled. Until the first signed feed is
uploaded at release time, a release build's check finds no feed there and
offers nothing.

## What is in the code

- **Sparkle 2.10.1**, pinned in Package.swift by the SHA-256 of its
  `Sparkle-for-Swift-Package-Manager.zip`
  (`4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a`, the
  same checksum as that release's own Package.swift). MIT; see
  [THIRD_PARTY.md](THIRD_PARTY.md).
- **Release builds only** (`Scripts/bundle-app.sh --release`) embed
  `Contents/Frameworks/Sparkle.framework` with what Sparkle ships inside it
  (Autoupdate, Updater.app, the Installer and Downloader XPC services; the
  XPC services are used only by sandboxed apps, and Owlink isn't
  sandboxed) and its licence as `Contents/Resources/Sparkle-LICENSE.txt`.
  Check builds have no Sparkle and never update.
- **Nothing is linked.** The app loads Sparkle with `dlopen` after the first
  frame, and only in a release build whose Info.plist holds an `https://`
  feed, a 32-byte EdDSA public key and `SURequireSignedFeed` = true
  (`Sources/CedricCore/UpdateConfig.swift`, `Sources/CedricApp/Updater.swift`).
  A check build (`CEDRIC_CHECKS`) is always off (`.disabled(.checkBuild)`),
  whatever its plist says, so the tests never load Sparkle or go to the
  network. Nothing of Sparkle's is on the launch path.
- **Info.plist** (written by bundle-app.sh): `SUFeedURL` and `SUPublicEDKey`
  are the committed values in `Scripts/sparkle-defaults.sh`
  (`https://owlink.app/appcast.xml` and `hrWeLLjfQFt7O50s1x4JepXV7dXLmpEztAuhe1XcsQs=`),
  unless `CEDRIC_SPARKLE_FEED_URL` / `CEDRIC_SPARKLE_PUBLIC_KEY` are set
  (and not empty) to override them, for a test build or a future key
  rotation. `SURequireSignedFeed` = true (the appcast itself must carry an
  EdDSA signature), `SUVerifyUpdateBeforeExtraction` = true,
  `SUEnableAutomaticChecks` = true (about once a day, until the user turns
  it off in Settings), `SUAutomaticallyUpdate` = false (never installs
  without asking). bundle-app.sh refuses a feed or key with whitespace or
  `< > & " '`, and a feed that isn't `https://` (but see the loopback
  exception below).
- **Loopback exception, for a local test only.** The app and bundle-app.sh
  also take a plain `http://` feed whose host is exactly `127.0.0.1` or
  `localhost` (any port, no user or password), so an older test build can
  update from a signed feed served on the same Mac (see "Testing an update
  locally"). No other `http://` host is taken, Sparkle still requires the
  signed feed and signed updates, and `release.sh` refuses any feed that
  isn't `https://`.
- **Signing order** (`Scripts/sign-sparkle.sh`, used by release.sh and by
  bundle-app.sh's ad-hoc signing, `Scripts/sign-adhoc.sh`): Installer.xpc,
  Downloader.xpc (keeps its entitlements), Autoupdate, Updater.app, the
  framework, then the app. Never `--deep` to sign, only to verify.
  release.sh checks that all of them have the app's Team ID and the hardened
  runtime.
- **`Scripts/release.sh --appcast`** (off by default; the normal release is
  unchanged): signs the notarized zip with Sparkle's `sign_update`, checks the
  signature against the build's public key (`Scripts/ed-verify.swift`, so
  a key mismatch stops the release), checks that the built Info.plist
  carries that feed URL and key, adds an `<item>` to a local
  `dist/appcast.xml`, signs that feed, verifies it, and prints the two files
  to upload and where. The new feed is built, signed and verified in a temp
  `.xml` beside `dist/appcast.xml` (`Scripts/appcast-item.sh`) and replaces
  it only once it verifies, so a failed run keeps the last signed feed and
  can simply be run again. **It uploads nothing.** The feed URL and public key
  are the committed ones unless `CEDRIC_SPARKLE_FEED_URL` /
  `CEDRIC_SPARKLE_PUBLIC_KEY` override them (release.sh notes an override);
  it refuses to start without a download URL and exactly one private-key
  source, or with a feed that isn't `https://` or a key that isn't 32 bytes.
  It also refuses a key file inside the repository or one others can read, and
  a release that skips notarization or is built for one architecture only
  (`--host-arch`: the appcast item is offered to every Mac). `Scripts/updates-check.sh` tests those
  refusals.

## Signing in CI

After the notarized zip passes the launch smoke test, release.yml:

1. writes `SPARKLE_ED_PRIVATE_KEY` to `$RUNNER_TEMP/sparkle-key/ed25519.key`
   (umask 077, folder 700, file 600; outside the checkout, never logged, no
   `set -x`), and stops unless the key's public half
   (`Scripts/sparkle-public-key.swift`, which prints only the public key) is
   the committed `hrWeLLjfQFt7O50s1x4JepXV7dXLmpEztAuhe1XcsQs=`;
2. signs `dist/Owlink-<version>.zip` with `sign_update --ed-key-file`,
   checks the reported length against the zip's size and the signature with
   `Scripts/ed-verify.swift` and the committed public key;
3. writes `dist/appcast.xml` as a new feed with that one item
   (`Scripts/appcast-item.sh`, which signs and verifies the feed). The
   enclosure is the tag's release asset,
   `https://github.com/d4rkwyng/owlink/releases/download/<tag>/Owlink-<version>.zip`
   (`<version>` is the tag without `v` and any `-rcN` suffix, as for the zip);
4. prints the zip's sha256 (also in the job summary), deletes the key
   folder in an `if: always()` step, even when signing failed, and attaches
   the zip and `appcast.xml` to the **draft** release. Nothing is published:
   not the release, not `https://owlink.app/appcast.xml`.

The appcast is a fresh one-item feed (no `--from`): once older versions are
listed, merge by hand or add the published feed as `--from`.
`.github/workflows/verify-sparkle-key.yml` (run by hand, `contents: read`)
checks the secret the same way on a dummy file and prints only PASS or FAIL.

## Decided

- **Signing key.** Derek created the EdDSA key pair. The private key is in
  his login Keychain (made with a bare `generate_keys`, so under Sparkle's
  default account, `ed25519`); it never goes in the repository, a script or
  a CI log. Back it up offline (`generate_keys -x <file outside the repo>`,
  then delete that file): if it is lost, installed copies can't take
  another update. The **public key** is committed (it is not secret):
  `hrWeLLjfQFt7O50s1x4JepXV7dXLmpEztAuhe1XcsQs=`.
- **Feed URL:** `https://owlink.app/appcast.xml`, permanent (every installed
  copy keeps it).
- **Where they go:** committed as defaults in `Scripts/sparkle-defaults.sh`,
  read by bundle-app.sh and release.sh, so every release build, including
  the GitHub release workflow's (`.github/workflows/release.yml`), carries
  them. The environment variables remain as overrides.
- **CI signing.** `.github/workflows/release.yml` signs the update on a tag
  (below, "Signing in CI"). The private key is the repository secret
  `SPARKLE_ED_PRIVATE_KEY` (`generate_keys -x` output: base64 of the 32-byte
  seed); only release.yml and the dispatch-only `verify-sparkle-key.yml` get
  it, never `tests.yml` or anything run on a pull request.
- **Automatic checks: on by default** (`SUEnableAutomaticChecks` = true).
  Sparkle checks about once a day and **still asks before installing**
  (`SUAutomaticallyUpdate` = false). The user can turn the daily check off
  in Settings › General.

## Waiting for the release (not done here)

- **Hosting.** Nothing is published at `https://owlink.app/appcast.xml` yet.
  Pick where the zips live (the GitHub release, as now, is fine) and write
  it as `CEDRIC_SPARKLE_DOWNLOAD_URL` with `{version}` in it (`https://`).
  Until a signed feed is uploaded, a release build's check finds nothing.
- **Publishing the feed.** CI signs the zip and writes a signed
  `appcast.xml` (below), but uploads nothing to owlink.app. After publishing
  the draft release, Derek copies its `appcast.xml` to
  `https://owlink.app/appcast.xml` by hand. Locally, `release.sh --appcast`
  (below) still does the same signing from the Keychain key.
- **Homebrew cask (`d4rkwyng/tap/owlink`).**
  - Sparkle replaces `/Applications/Owlink.app` in place. The cask's
    `binary` link to `Contents/Resources/cedric` keeps working, and `zap`
    already covers Sparkle's cache (`~/Library/Caches/net.mindtricks.cedric`).
  - Owlink can't see the cask, so a Homebrew copy checks daily too (it asks
    before installing; its user can turn the check off).
  - **`auto_updates true`**: add it to the cask, but **not in the same bump
    as the first version with updates on**. With `auto_updates true`,
    `brew upgrade` skips the cask (unless `--greedy`), and older copies
    can't update themselves, so they would stay behind. Bump the cask
    without it to the first update-enabled version. Add `auto_updates true`
    in a later bump, once most users have that version. Until then, a copy
    Sparkle already updated gets the same version again on `brew upgrade`,
    which is harmless.

## First signed release, step by step

1. Choose the download URL and set up the hosting for the feed (above).
2. Dry run, which uploads nothing and signs nothing (the feed and public
   key are the committed ones):
   ```sh
   CEDRIC_SPARKLE_DOWNLOAD_URL='https://…/v{version}/Owlink-{version}.zip' \
   CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=ed25519 Scripts/release.sh --dry-run --appcast
   ```
3. The real run: the same command without `--dry-run`. It builds, signs,
   notarizes, staples, launch-checks, zips, signs the zip for Sparkle,
   verifies it against the public key, checks the app's Info.plist has the
   feed and key, and writes and signs `dist/appcast.xml`. From the next
   release on, pass the published feed as `CEDRIC_SPARKLE_APPCAST=<local
   copy>` so the new item is added to it.
4. Upload by hand, in this order: the zip to its download URL, then
   `dist/appcast.xml` to `https://owlink.app/appcast.xml`.
5. Bump the cask as usual (version and sha256), without `auto_updates` (see
   above).
6. The first update-enabled release has nothing to update from. The first
   real test is the next release: install the update-enabled version,
   publish the next one, and use Check for Updates….

## Testing an update locally

An older build can be updated to a newer one on this Mac without the real
key, the real feed or the network, using the loopback exception (done this
way for 0.6; nothing here touches the real key or the real data):

1. A throwaway EdDSA key that is not Derek's. `generate_keys --account
   <throwaway>` works, but `sign_update --account` then asks for the login
   Keychain password before it can read that item; unattended, use a key
   file instead: 32 random bytes as base64 in a `chmod 600` file in a temp
   folder (CryptoKit's `Curve25519.Signing.PrivateKey().rawRepresentation`),
   its public key from `.publicKey.rawRepresentation`, and
   `sign_update --ed-key-file <file>`. Never the default Keychain account
   (`ed25519`), which holds the real key.
2. Two `bundle-app.sh --release --out <temp>` builds, with `CEDRIC_VERSION`
   set to an older and a newer version, `CEDRIC_SPARKLE_PUBLIC_KEY` = the
   throwaway public key and
   `CEDRIC_SPARKLE_FEED_URL=http://127.0.0.1:<port>/appcast.xml`. Give both
   copies the same test `CFBundleIdentifier` (say
   `net.mindtricks.cedric.sparkletest`) and re-sign them with
   `Scripts/sign-adhoc.sh`, so they never share `net.mindtricks.cedric`'s
   defaults.
3. Zip the newer app (`ditto -c -k --keepParent`), sign the zip, write an
   appcast with that item (`swift Scripts/appcast-insert.swift - appcast.xml
   <version> <url> <length> <signature> <date>`), sign the appcast with
   `sign_update` too, and serve the folder with
   `python3 -I -m http.server <port> --bind 127.0.0.1`.
4. Launch a copy of the older app through Launch Services with a temp
   home: `open -n --env CFFIXED_USER_HOME=<temp home> <copy>/Owlink.app`.
   A release binary ignores the test folder overrides; the temp home is what
   keeps it out of the real `~/Library/Application Support/Cedric` (its
   user defaults still go to the real `~/Library/Preferences`, under the test
   bundle id; delete that domain afterwards). The automatic check fetches the
   feed at launch and offers the update.
5. To install without clicking (a locked screen can't be clicked), set
   `defaults write <test bundle id> SUAutomaticallyUpdate -bool YES` for the
   test domain only: Sparkle downloads and verifies in the background and
   installs when the app quits, without relaunching it. Quit the copy
   (`NSRunningApplication(processIdentifier:).terminate()`), then check its
   `CFBundleVersion`. Never let Sparkle relaunch an updated copy (Install and
   Relaunch): Launch Services would start it with the real home.
6. The same with an item whose `edSignature` is wrong, one with none, and a
   feed edited after signing: the copy must stay at the older version (the
   last is refused before the zip is even downloaded).

## Not done yet

- No release notes in the appcast item (Sparkle shows the item's title only).
  A `<sparkle:releaseNotesLink>` to the GitHub release could be added.
- No delta updates.
- release.yml writes a one-item feed; it doesn't merge into the published
  appcast (`--from`) or upload it.
