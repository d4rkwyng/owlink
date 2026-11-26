# Updates (Sparkle 2): what is built, and what Derek must decide

Status: **code only, turned off.** No signing key exists, no feed is
published, and no URL for one is chosen. Every build made today has an empty
`SUFeedURL` and `SUPublicEDKey`, so the updater is off:
Owlink › Check for Updates… is disabled with a tooltip, Settings › General ›
Automatically check for updates is off and disabled, Sparkle.framework is
never loaded, and nothing goes to the network.

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
  frame, and only when the Info.plist holds an `https://` feed, a 32-byte
  EdDSA public key and `SURequireSignedFeed` = true
  (`Sources/CedricCore/UpdateConfig.swift`, `Sources/CedricApp/Updater.swift`).
  So the default build pays nothing at launch.
- **Info.plist** (written by bundle-app.sh): `SUFeedURL` and `SUPublicEDKey`
  from `CEDRIC_SPARKLE_FEED_URL` and `CEDRIC_SPARKLE_PUBLIC_KEY` (empty by
  default), `SURequireSignedFeed` = true (the appcast itself must carry an
  EdDSA signature), `SUVerifyUpdateBeforeExtraction` = true,
  `SUEnableAutomaticChecks` = false, `SUAutomaticallyUpdate` = false (never
  installs without asking).
- **Signing order** (`Scripts/sign-sparkle.sh`, used by bundle-app.sh and
  release.sh): Installer.xpc, Downloader.xpc (keeps its entitlements),
  Autoupdate, Updater.app, the framework, then the app. Never `--deep`.
  release.sh checks that all of them have the app's Team ID and the hardened
  runtime.
- **`Scripts/release.sh --appcast`** (off by default; the normal release is
  unchanged): signs the notarized zip with Sparkle's `sign_update`, checks the
  signature against `CEDRIC_SPARKLE_PUBLIC_KEY` (`Scripts/ed-verify.swift`, so
  a key mismatch stops the release), adds an `<item>` to a local
  `dist/appcast.xml`, signs that feed, verifies it, and prints the two files
  to upload and where. **It uploads nothing.** It refuses to start without a
  feed URL, public key, download URL and exactly one private-key source.
  It also refuses a key file inside the repository or one others can read, and
  a release that skips notarization. `Scripts/updates-check.sh` tests those
  refusals.

## Decisions and OKs needed

### 1. Create the signing key (needs your OK)

Run once on the Mac that makes releases, with the tools of the pinned
version (after `swift build` they are in
`.build/artifacts/<checkout>/Sparkle/bin/`, or in Sparkle 2.10.1's release
download):

```sh
.build/artifacts/*/Sparkle/bin/generate_keys --account owlink
```

- The **private key** is stored in your login Keychain (an item for
  account `owlink`, separate from any other app's Sparkle key). It never goes
  in the repository, a script or a CI log.
- The command prints the **public key** (base64, 44 characters). That is the
  `SUPublicEDKey` value. It is not secret. `generate_keys --account owlink -p`
  prints it again later.
- **Back the private key up** to offline storage (a password manager):
  `generate_keys --account owlink -x <file outside the repo>`, then delete
  that file. If the key is lost, installed copies can't take another update
  (they only trust that key).
- For CI signing later: store the exported key as a GitHub secret, write it to
  a `chmod 600` temp file outside the checkout, and point
  `CEDRIC_SPARKLE_KEY_FILE` at it. Locally, use
  `CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=owlink`.

### 2. Feed URL and hosting

Pick one permanent `https://` URL for `appcast.xml`. Every installed copy
keeps it, so it must not move. Options: a page on the Owlink site (static
file, you upload the new appcast each release), or a GitHub release asset
URL. Also pick where the zips live (the GitHub release, as now, is fine) and
write it as `CEDRIC_SPARKLE_DOWNLOAD_URL` with `{version}` in it. Both must be
HTTPS: the app refuses anything else.

### 3. Where `SUPublicEDKey` and the feed URL go

Either:

- **set them at release time** (`CEDRIC_SPARKLE_PUBLIC_KEY`,
  `CEDRIC_SPARKLE_FEED_URL` in the environment of `release.sh --appcast`),
  or
- **commit them as defaults** in `Scripts/bundle-app.sh` (both are public),
  so every release build, including the GitHub release workflow's
  (`.github/workflows/release.yml`, which runs release.sh without
  `--appcast` today), carries them.

If you set them only by hand, a CI-built release ships with updates off.

### 4. Homebrew cask (`d4rkwyng/tap/owlink`)

Today nothing changes for cask users: the feed is empty, so the updater is
off.

Once updates are on:
- Sparkle replaces `/Applications/Owlink.app` in place. The cask's `binary`
  link to `Contents/Resources/cedric` keeps working, and `zap` already covers
  Sparkle's cache (`~/Library/Caches/net.mindtricks.cedric`).
- Owlink can't see the cask. Automatic checks stay off by default, so a
  Homebrew copy checks only if its user turns them on or chooses Check for
  Updates….
- **`auto_updates true`**: add it to the cask, but **not in the same bump as
  the first version with updates on**. With `auto_updates true`,
  `brew upgrade` skips the cask (unless `--greedy`), and older copies can't
  update themselves, so they would stay behind. Bump the cask without it to
  the first update-enabled version. Add `auto_updates true` in a later bump,
  once most users have that version. Until then, a copy Sparkle already
  updated gets the same version again on `brew upgrade`, which is harmless.

### 5. Automatic checks default

Off (`SUEnableAutomaticChecks` = false) until you decide. Turning it on by
default means changing that line in bundle-app.sh. Sparkle then checks about
once a day, and still asks before installing.

## First signed release, step by step

1. OK the key (section 1) and create it. Note the public key.
2. Choose the feed URL and download URL (section 2), and set up the empty
   hosting.
3. Decide section 3 (env or committed defaults).
4. Dry run, which uploads nothing and signs nothing:
   ```sh
   CEDRIC_SPARKLE_FEED_URL=… CEDRIC_SPARKLE_PUBLIC_KEY=… \
   CEDRIC_SPARKLE_DOWNLOAD_URL='https://…/v{version}/Owlink-{version}.zip' \
   CEDRIC_SPARKLE_KEYCHAIN_ACCOUNT=owlink Scripts/release.sh --dry-run --appcast
   ```
5. The real run: the same command without `--dry-run`. It builds, signs,
   notarizes, staples, launch-checks, zips, signs the zip for Sparkle,
   verifies it against the public key, and writes and signs
   `dist/appcast.xml`. From the next release on, pass the published feed as
   `CEDRIC_SPARKLE_APPCAST=<local copy>` so the new item is added to it.
6. Upload by hand, in this order: the zip to its download URL, then
   `dist/appcast.xml` to the feed URL.
7. Bump the cask as usual (version and sha256), without `auto_updates` (see
   section 4).
8. The first update-enabled release has nothing to update from. The first
   real test is the next release: install the update-enabled version,
   publish the next one, and use Check for Updates….

## Not done yet

- No release notes in the appcast item (Sparkle shows the item's title only).
  A `<sparkle:releaseNotesLink>` to the GitHub release could be added.
- No delta updates.
- release.yml doesn't run `--appcast`.
