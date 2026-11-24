# Owlink for iPhone and iPad

The iOS app lives in `ios/` and builds on the same `CedricCore` and
`CedricAI` packages as the Mac app; only the UI is separate.

| | |
|---|---|
| Project | `ios/Owlink.xcodeproj`, scheme **Owlink** |
| Bundle ID | `app.owlink.ios` |
| Version | 0.5.2 (17), set in `ios/Scripts/gen-xcodeproj.py` |
| Devices | iPhone and iPad (universal), iOS 17 or later |
| Signing | Automatic, team `V868MD2SHX` |

The project file is generated: edit `ios/Scripts/gen-xcodeproj.py` and run
`python3 ios/Scripts/gen-xcodeproj.py`, rather than changing build settings
in Xcode (a change made in Xcode is lost the next time the script runs).
Source files can be added in Xcode or Finder: `ios/Owlink`,
`ios/OwlinkUITests` and `Tests/*` are synchronized folders.

## New in 0.5.2 (16)

Brings the shared code up to Mac Owlink 0.5.2 (tag v0.5.2) and matches
its changes where they apply on iOS:

- **Web links always ask first.** A tap on a web link in the preview no
  longer opens the page in the preview's own browser: it asks first, and
  only Open hands it to Safari (or your default browser). The question
  names the site on a line of its own (a name in non-Latin look-alike
  letters is shown as its plain-ASCII form and flagged), points out a
  user name placed before the site to disguise it, and has Cancel as its
  default; one question at a time. Redirects, refreshes, forms and frames
  can't load a web page in the preview either, and a link to a place in
  the page needs a real `#` in the page itself. **Open in Browser** is
  gone from the preview, with the in-preview browser.
- **Linked documents load from their real location.** A document opened
  through a symbolic link takes its type (Markdown or HTML) and its
  folder for images and links from the file that was checked and read.
- **Obsidian vault bounds.** A stray `.obsidian` folder in the app's own
  container or above it never becomes the vault; a vault found inside a
  folder you granted follows the same rules. A granted folder with no
  vault in it is still the vault, as an opened folder is on the Mac.
- **Reopen files from last session** reads its setting as the Mac does,
  so a `-reopenFilesFromLastSession NO` launch argument turns it off.
  It was already on unless turned off in Owlink; unsaved text from the
  last session is still offered at launch when it doesn't reopen.
- **Edited** already followed the text, as the Mac's new unsaved mark
  does: it clears on save, on Revert, and on undo back to the saved
  text. A test now covers it.
- Shared speed tests hold this thread's CPU time, scaled by how busy the
  machine is, to their bounds (best of several tries), so they no longer
  fail on a loaded Mac or simulator without loosening what they check.

Not on iOS: the Mac's • tab and title mark (iOS shows "Edited"), Finder
document icons, and the Mac's multi-tab session (unsaved untitled tabs,
Reopen Closed Tab).

Build 17 (fixes from a device check of build 16):

- **The ••• menu is tidied.** Focus Preview is in it once, in its Preview
  submenu beside Preview and Open Preview in New Window, on iPhone and
  iPad at any width (bar buttons that don't fit no longer add themselves
  to the menu a second time). The menu is in groups: view and preview;
  Save, Print and Export; find, marks and navigation; then the rest.
- **The format bar hides under Ask Cedric.** The Markdown format bar
  leaves the keyboard while the Ask Cedric sheet is up and comes back,
  as it was, when the sheet closes (Done, swipe down, or any other way).
- **US English spellings** throughout: Summarize, color, center, license.
- **Settings opens without Ask Cedric.** ⌘, and the menu bar's Settings…
  (and the other menu-bar commands) reach the editor with nothing in it
  selected, and from a sheet over it; Settings opens on top of Ask
  Cedric, which stays open.
- **The back button works again** whatever is shown over the document:
  closing takes the editor away with any sheet over it.
- **Front matter is collapsed in the preview.** YAML front matter is one
  line, "Front matter · title"; a tap opens it, nested values as nested
  tables and lists, and the preview remembers whether you left it open.

## New in 0.5.1 (15)

Brings the shared code up to Mac Owlink 0.5.1 (tag v0.5.1) and matches
its changes where they apply on iOS:

- **Preview links.** A linked document is checked and read by the same
  resolved path (a symbolic link swapped in between can't point the read
  outside the folder, and a link is judged by its target's name). Page
  JavaScript and network stay off for every page the preview shows,
  after a link, Back, Forward or This Document and after the document
  changes on disk (iOS has no JavaScript/Network switch to reset).
  Browsing with Back, Forward and This Document, the prompt before a web
  page leaves the app, and links to a heading in another document were
  already on iOS.
- **Obsidian images in a granted folder.** When the folder you granted
  holds several vaults (iCloud Drive › Obsidian), the preview, export and
  Copy as HTML use the note's own vault, so its `attachmentFolderPath`
  is read and a bare image name doesn't resolve to another vault.
- **VoiceOver names**, as on the Mac: Ask Cedric's scope chip ("Asking
  about") and question field ("Question for Cedric"), the Go to Line
  field ("Line number"), and the server address in Settings.
- **Localized copy**: the font size units in Settings, the Go to Line
  placeholder, the owl hint bar's VoiceOver label and Fix Typos' quoted
  word.
- **Ask Cedric** (shared AI code): a server on your network now gets the
  Mac's larger whole-file context (32,000 characters), so a model such
  as Qwen can review a whole file when it fits; the built-in model keeps
  iOS's 8K-token window (12,000 characters) and Apple Intelligence its
  5,000. The model's name in the header, typing dots and one combined
  whole-file answer were already on iOS.

Not on iOS: the folder sidebar's actions menu and resize fix (no folder
sidebar), Finder document icons, and the Mac's multi-tab session restore
(iOS reopens the last document, as since 0.4.5).

## New in 0.4.6 (14)

- **Code folding**, as on the Mac: the ⋯ menu's Folding submenu (and iPad
  Text › Folding), fold marks in the line-number gutter, and a "⋯ N lines"
  pill that unfolds. Folded text is only hidden; save, undo, find, copy,
  print and export see all of it.
- **Fix Typos…** (the ⋯ menu, and iPad Edit › Spelling and Grammar, ⌥⌘;)
  steps through misspelled words one at a time with the on-device checker:
  Change, Change All, Skip, Ignore All, Learn Word and Done. A word inside a
  fold opens the fold when Fix Typos reaches it.

Details for both are under What it does below.

## What it does

- Text menu and touch line commands, indentation conversion, and cancellable keep/delete lines matching.
- Settings › Editor sets the default indent for files without detected indentation.
- This document's Indent Using Spaces/Tabs and Tab Width are in the ⋯ menu (Indentation) and apply until the document is closed or reloaded.
- Read-only CSV and TSV grid preview in the editor palette: pinned header, zoom, sortable columns (a third tap restores file order), VoiceOver sort state, and field navigation back into the text.
- Opens and saves files from the Files app, iCloud Drive and other file
  providers (a document browser in each window). The encoding and line
  ending are detected and written back unchanged (the core's `TextCodec`).
- Syntax coloring (the core's highlighter), the seven themes including
  Dracula, font size, wrap, and **Show Line Numbers** (on by default).
  Settings can pick the monospaced editor font (SF Mono or another installed
  monospaced family); the choice is remembered.
  Settings › Writing can use a prose font for Markdown and plain text; code
  keeps the monospaced editor font.
  **Check spelling while typing** and **Check grammar in prose** (Settings,
  and iPad Edit › Spelling and Grammar) use the system's checker for Markdown
  and plain text, stay off for code and data files (and while a large
  document pauses the extras), and are on until turned off. Grammar needs
  iOS 27; before that the setting is kept but does nothing. Unlike the Mac,
  the system marks the whole document, so fenced code and markup in Markdown
  may be underlined too.
  **Fix Typos…** (the editor's ••• menu, and iPad Edit › Spelling and
  Grammar, ⌥⌘;) steps through the misspelled words one at a time with the
  on-device checker, in the same documents the Mac checks (prose, and
  comments and strings in code; never data files): Change, Change All,
  Skip, Ignore All, Learn Word and Done.
  Jumps show numbers for the open file even when the setting is off.
- Return keeps the current indent, and brackets and quotes pair in code as
  on the Mac; **Auto-close brackets and quotes** is in Settings (on by default).
- Writing Mode offers typewriter scrolling and paragraph or sentence focus per open editor.
- Show Invisibles marks spaces, tabs and line endings without changing the text, even on long lines.
- Highlight occurrences (on by default) and matching brackets (always on, as on the Mac), using the current theme without repainting all occurrences on each caret move.
- Find and replace (`⌘F`, `⌥⌘F`, or the magnifier and the ⋯ menu).
- Mark All / Clear Marks (the ⋯ menu, the find navigator's options menu, and on iPad Edit › Find with `⌃⌘M` / `⌃⇧⌘M`) mark every occurrence of the selection or the word under the caret, as on the Mac, until cleared; the count shows in the status bar.
- Bookmark Line, Next/Previous Bookmark and Clear Bookmarks are in the ⋯ menu (and on iPad Text › Bookmarks, with `⌘F2`, `F2`, `⇧F2` and `⇧⌘F2`); markers are drawn in the line-number gutter, and a tap on a line number toggles that line.
- Code folding (0.4.6), as on the Mac: Fold, Unfold, Fold All, Unfold All and Fold to Level 1–3 are in the ⋯ menu's Folding submenu (and on iPad Text › Folding, with `⌥⌘←`, `⌥⌘→`, `⌥⇧⌘←` and `⌥⇧⌘→`). Languages that fold show ▾ beside each foldable line in the gutter and ▸ on a folded one; tap it to fold or unfold, or tap the "⋯ N lines" pill. Folded text is only hidden: save, undo, find, copy, print and export see all of it, and arrow keys step over a fold. Plain text, CSV, diffs, batch, .reg, HTML and XML don't fold, and a large document turns folding off. Folds aren't kept when the document closes.
- Offline Text Tools: Explain Regex and Decode Selection in the edit menu,
  and Find TODOs in the edit and document menus. Results stay on the device.
- Statistics: word count in the status line, document and selection counts,
  reading time and a per-file word goal in Statistics. Goals stay in settings,
  not in the file.
- Statistics also tracks a daily word target across documents, including edits made while a large document's opening count is calculated, resetting at local midnight.
- Copy Markdown as HTML or rich text from the edit menu or iPad Edit menu, with VoiceOver announcements for copy errors.
- Find and Replace supports regular expressions (the **Regex** option in the find navigator's options menu, remembered between launches; `$1` in replacements). Replace All is one undo step and is limited to 200,000 replacements; live results stop at 10,000 matches.
- Markdown Context Bar above the keyboard and Format › Markdown commands:
  bold `⌘B`, italic `⌘I`, strikethrough `⇧⌘X`, inline code Control-backtick,
  link `⌘K`, headings `⌘1`–`⌘3`, and checkbox `⌘↩`.
  Return continues or ends Markdown lists; hardware Tab and ⇧Tab move through
  table cells or indent and outdent list items. Pasting a URL over selected
  text makes a Markdown link.
- Data safety: "Edited" under the title while there are unsaved changes
  (UIDocument's `hasUnsavedChanges`); Undo and Redo in the bar; Revert to
  Opened Version in the ⋯ menu (a private copy of the file as opened, in
  Caches, not kept over 20 MB, deleted on close; the revert is one Undo).
  Settings › Saving › Save Automatically (on by default): off, the file
  changes only on Save (`⌘S` or the bar's Save) and closing asks Save /
  Don't Save / Cancel. Either way, unsaved text is copied every 3 s at most
  to Application Support/Owlink/Recovery (out of backups) and offered after
  a crash or a forced quit. Settings › Reopen files from last session (on
  by default): the last open document opens again at launch if the file is
  still there; closing it first, or turning this off, starts at the
  document browser (`LastOpenDocument`). Rules and stores: `SavePolicy`, `RecoveryStore`,
  `RevertStore` in CedricCore (`SaveSafetyTests`). Debug builds:
  `-OwlinkSaveCheck <dir>` runs these in the app and writes `savecheck.txt`
  and PNGs.
- Markdown preview (`⇧⌘P`), side by side on iPad and an unfolded iPhone
  Duo. **Focus Preview** (the bar's expand button, the ⋯ menu, `⌥⌘P`)
  shows the preview alone on any screen; back with Edit, Esc, `⇧⌘P`, a
  swipe down at the top of the page or a swipe in from the leading edge.
  Print documents, or export Markdown as HTML or a rendered PDF, from the
  document menu. Exported and printed Markdown PDFs are cut between
  blocks (the Mac's `PageBreaks`), so a line is not split across pages
  when a block boundary fits. Bare image names (`<img>`, `![]()`, `![[ ]]`) are found
  in the vault, including `Images/` and the vault's `attachmentFolderPath`,
  with width and float kept; a granted folder above the vault uses the
  note's own vault (`WikiVault.vaultRoot`).
  Links browse in the preview (attached and detached), with **Back**,
  **Forward** and **This Document**: a Markdown or HTML file the link
  rules allow renders there under the same policy (JavaScript off, strict
  CSP); other text files open in the editor; a linked file is checked and
  read by its resolved path, which also gives its kind and folder. A web
  page never loads in the preview (0.5.2): a tap (or `⌘`-tap) on a web or
  mail link asks first, naming the site on its own line (a non-ASCII name
  as its punycode, flagged; a user name before the `@` called out), with
  Cancel as the default, and only Open hands it to the system. Redirects,
  refreshes, forms and frames can't load another page. Nothing a link
  names is launched.
  A link with a heading fragment (`other.md#part`, `page.html#sec`,
  `[[other#Part]]`) opens that document in the preview at the heading, and
  Back / Forward return to it.
  Text and preview open at the same place both ways (`ScrollSync`). Side
  by side, the handle between them drags (44 pt wide) and snaps to 1/3,
  1/2, 2/3 and the fold (the default, a strong snap); double-tap resets
  it; kept per size class; VoiceOver "Resize preview", swipe up or down
  for the stops. Pinch the preview (or `⌘+`, `⌘−`, `⌘0` in Focus
  Preview) for its text size, kept for the app, on top of Dynamic Type.
  The page is laid out at the device width (a viewport; it was laid out
  980 px wide and shrunk). Rules: `PreviewSplit`, `PreviewSplitStore`,
  `PreviewZoom` (`PreviewSplitTests`).
- Never three columns (`EditorPanes`, `EditorPanesTests`): on a wide
  screen Ask Cedric is always the side panel and takes the preview's
  place while open (a sheet left up from the folded phone becomes the
  panel on unfolding); the owl stays in the text pane, off the panel.
- Cedric's offline hints with **Fix it**; Ask Cedric (`⇧⌘K`) and Check
  with Cedric (`⌥⌘H`).
- iPad: menu bar and keyboard shortcuts, several windows, Stage Manager.
- Cedric sits in the editor's corner as on the Mac (the same owl art):
  tap him for his bubble with the waiting hint (a count badge and a short
  pulse say one arrived; no pulse with Reduce Motion), or for Ask Cedric
  when there is none; drag him to another edge or corner (he snaps, and
  the place is kept); double-tap puts him back; long-press for his menu.
  He fades while the caret is near him. In a landscape phone's vertical
  navigation rail he uses its bottom when there is room; a saved custom
  position stays in the editor.
- Ask Cedric is a sheet on a phone and a panel beside the text on a wide
  screen (iPad, an unfolded iPhone Duo).
- Ask Cedric's scope chip, above the question field (VoiceOver: "Asking
  about"; the field is "Question for Cedric"): Selection (with a
  selection), Visible text or Whole document (the default without a
  selection). A file too big for the model sends whole lines around the
  caret and the chip names them ("Lines 40–160 of 900 (trimmed to fit)").
  Explain, Find Problems and typed whole-document questions review a file
  that doesn't fit in up to eight overlapping parts, then combine their
  answers into one response; progress says “Reviewing…” without part counts,
  with a note on any lines not reviewed (`OwlChunkedReviewRunner`). **Check
  Script for Risks…** (the chip, the ⋯ menu, the owl's menu and the iPad's
  Cedric menu, for shell, PowerShell, batch, .reg, Python and Ruby) runs the
  shared offline scan (`ScriptSafety`): nothing is executed and nothing is
  sent anywhere for the scan, and the findings show as "Offline scan (no AI)"
  with the same summary as the Mac. When Ask Cedric has an engine, the
  model's review and the `ScriptVerdict` clamp follow, as on the Mac.
- **Explain Selection** and **Rewrite Selection** in the text's edit menu
  and the Cedric menu (`⌥⌘E`, `⌥⇧⌘E`): the exact selection (clipped to
  the model, with a note when it was), Rewrite only with a model that
  passes the tool gate and not read-only, as Apply / Skip cards; Ask
  Again re-asks the original selection or says it changed.

### iPhone Duo

Opening and closing the phone is a size-class change (compact outside,
regular inside). Unfolded, text and Markdown preview meet at the fold
(the system's `.division` reserved region), and the owl, his bubble, the
toast and the Ask Cedric panel keep off it. Folded shut with the preview
on, the preview takes the screen; reopening puts back the caret,
selection, scroll position and keyboard. The status line and the text
stay inside the safe area and clear of the rounded corners and the
vertical bar the system moves the toolbar into; the toolbar's extra
commands are in the system's overflow menu. The font defaults to 15 pt
unfolded and 13 pt folded unless one was chosen. Layout rules are pure
functions in CedricCore (`FoldLayout`, `OwlPlacement`, `OwlBadge`,
`EditorContinuity`) with tests in `DuoLayoutTests`.

On iOS, as on the Mac: the writing checks run with Cedric’s offline hints.
Settings › Writing holds the prose font setting, Style Check and Readable
Width. Style Check and Readable Width are off until turned on; the document
menu also switches Readable Width for the open file. Open Quickly (⌥⌘O)
finds files in a folder Owlink can list and the
headings of the open Markdown document. Ask Cedric can call check_document
and read_section, and a propose_edit is a card with Apply and Skip (never
applied while the file is read-only).

Not on iOS: the `cedric` command, Replace in Files, the folder sidebar, Git,
the certificate view, XML formatting, and the command palette’s menu
commands.

## Cedric AI on iOS

Off by default, as on the Mac. The offline hints never use the network.

**Use Cedric AI** turns the engines on; **Check automatically when I
pause typing** is separate. For a server on your network it is off by
default, and turning it on first asks to confirm that the visible text
(up to 8 KB) goes to that server (`CedricServerAutomaticChecksAcknowledged`,
the Mac's key); unconfirmed, automatic checks stay off (`AIStore`). No AI
hint is asked for an empty or near-empty document (`HintPrompt.hasEnoughText`).

- **Apple Intelligence** (iOS 26 or later on a device that supports it,
  with Apple Intelligence turned on). Settings › Cedric AI shows whether it
  is available, or why not (device not eligible, turned off, model not
  ready). On-device only; Private Cloud Compute is never used.
- **Built-in model** (llama.cpp): **real devices only**. The pinned
  XCFramework has an iOS device slice but no simulator slice, so simulator
  builds leave it out and Settings says "Built-in model: needs a real
  device". iPhones (and iPads without an M chip) are offered the small
  models (up to 2B parameters, about 1.1 GB); M-series iPads also the 3–4B
  ones. Downloads come from huggingface.co only when asked, show the full
  bundled license text first (Confirm once its end has been on screen;
  `-OwlinkShowLicence <id|first>` shows the sheet in Debug builds), are checked against their SHA-256, and are kept out of iCloud
  backups. Before loading, the app checks `os_proc_available_memory()` and
  refuses with a message rather than being killed for using too much memory.
  The built-in model uses an 8K-token context window on iOS (Ask Cedric
  sends it up to 12,000 characters of document; 24,000 on the Mac).
- **A server on your network** (LM Studio, Ollama, another Mac): local
  addresses only. Ask Cedric sends it up to 32,000 characters of document,
  as the Mac does, so a whole file goes in one request when it fits.

Device builds run `ios/Scripts/fetch-llama.sh` first, which takes the iOS
slice from SwiftPM's download cache or downloads the same pinned zip from
GitHub, and checks it against the SHA-256 in `Package.swift`.

## Option A: archive and upload from Xcode (recommended now)

On a Mac signed in to the Apple developer account for team V868MD2SHX:

1. `git checkout feat/ios-app` (once merged: `main`), then open
   `ios/Owlink.xcodeproj` in Xcode 27.1 or later (the iPhone Duo APIs
   need the iOS 27.1 SDK).
2. Xcode › Settings › Accounts: make sure the account is signed in.
3. Select the **Owlink** target › Signing & Capabilities: Team
   V868MD2SHX, "Automatically manage signing" on. Xcode registers the
   bundle ID `app.owlink.ios` and the Increased Memory Limit
   capability on first use.
4. In App Store Connect (https://appstoreconnect.apple.com) › Apps › **+**
   › New App: platform iOS, name "Owlink: Text & Code" ("Owlink" itself
   is taken), bundle ID `app.owlink.ios`, SKU e.g. `owlink-ios`.
5. In Xcode, choose the destination **Any iOS Device (arm64)**, then
   Product › **Archive**. The first device build downloads the llama.cpp
   zip (about 65 MB) unless SwiftPM already has it cached.
6. In the Organizer: **Distribute App** › **App Store Connect** ›
   Distribute. Xcode signs the app and the embedded `llama.framework`.
7. App Store Connect › the app › **TestFlight**: once the build has
   finished processing, answer the export-compliance question (the Info.plist
   already says no non-exempt encryption), add yourself as an internal
   tester, and install it with the TestFlight app.

Before an App Store release (not needed for internal TestFlight): a privacy
policy URL, the App Privacy answers ("Data Not Collected" matches
`PrivacyInfo.xcprivacy`), screenshots and a description.

## Option B: build in CI (GitHub Actions)

Not set up. What it would need:

- **Secrets** (created by Derek in App Store Connect › Users and Access ›
  Integrations › App Store Connect API, role App Manager):
  `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the .p8 file's contents).
  With an API key, `xcodebuild -allowProvisioningUpdates` can create the
  signing certificate and profiles itself (cloud-managed signing), so no
  certificate has to be exported into a secret.
- **A macOS runner** with Xcode 27.1 or later (`macos-26` or a self-hosted
  Mac).
- **Workflow outline** (`.github/workflows/ios-testflight.yml`, run by
  hand or on a tag):

```yaml
on: workflow_dispatch
jobs:
  testflight:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: API key
        run: |
          mkdir -p ~/.appstoreconnect/private_keys
          echo "$ASC_KEY_P8" > ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
        env: { ASC_KEY_P8: "${{ secrets.ASC_KEY_P8 }}", ASC_KEY_ID: "${{ secrets.ASC_KEY_ID }}" }
      - name: Archive
        run: |
          xcodebuild -project ios/Owlink.xcodeproj -scheme Owlink \
            -destination 'generic/platform=iOS' -archivePath build/Owlink.xcarchive \
            CURRENT_PROJECT_VERSION=${{ github.run_number }} \
            -allowProvisioningUpdates \
            -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_${{ secrets.ASC_KEY_ID }}.p8 \
            -authenticationKeyID ${{ secrets.ASC_KEY_ID }} \
            -authenticationKeyIssuerID ${{ secrets.ASC_ISSUER_ID }} \
            archive
      - name: Upload to TestFlight
        run: |
          cat > ExportOptions.plist <<'EOF'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>upload</string>
            <key>teamID</key><string>V868MD2SHX</string>
          </dict></plist>
          EOF
          xcodebuild -exportArchive -archivePath build/Owlink.xcarchive \
            -exportOptionsPlist ExportOptions.plist -exportPath build/export \
            -allowProvisioningUpdates \
            -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_${{ secrets.ASC_KEY_ID }}.p8 \
            -authenticationKeyID ${{ secrets.ASC_KEY_ID }} \
            -authenticationKeyIssuerID ${{ secrets.ASC_ISSUER_ID }}
```

The build number must go up with every upload (`CURRENT_PROJECT_VERSION`
above). A runner without SwiftPM's cache downloads the llama zip on every
run; caching `~/Library/Caches/org.swift.swiftpm` avoids that.

## Building and testing on this Mac

`xcode-select` may point at the Command Line Tools; use full Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ios
xcodebuild -project Owlink.xcodeproj -scheme Owlink -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project Owlink.xcodeproj -scheme Owlink -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodebuild -project Owlink.xcodeproj -scheme Owlink -destination 'generic/platform=iOS' \
  -archivePath /tmp/Owlink.xcarchive CODE_SIGNING_ALLOWED=NO archive   # proves the device build compiles and links llama
```

Test targets:

- `OwlinkCoreTests` and `OwlinkAITests` run the package's own
  `Tests/CedricCoreTests` and `Tests/CedricAITests` on the simulator
  (1012 + 265 tests at 0.5.1; `FileTailTests.stopLeavesNoDescriptor`
  fails on the simulator, a known issue; the Mac-only files are listed
  in `gen-xcodeproj.py`).
- `OwlinkUITests` (XCUITest) drives the app: open, edit, save and reopen;
  the owl's fix; the Markdown preview; find. It opens bundled samples with
  the launch argument `-OwlinkOpen <name>`, skipping the document browser.
- `OwlinkSnapshotTests` compiles the app's sources into a test bundle and
  drives the editor in a window, rendering PNGs.

Run the last two on a device or a simulator that can draw. On the fleet
Mac (geonosis) the iOS 27.2 simulator boots but never draws its home
screen (SpringBoard stays on the Apple logo; Metal in the simulator), so
apps can't launch there and any UIKit window hangs, in tests too. Run only
the first two there (`-only-testing:OwlinkCoreTests -only-testing:OwlinkAITests`).

### The self-check (debug builds)

`-OwlinkSelfCheck <dir>` runs the editor through a script inside the app
(open a sample, the owl's hint and Fix it, type, save and read the file
back, the language menu, find, the Markdown preview, Ask Cedric with
whatever engine is ready, the themes) and writes PNGs and
`selfcheck.txt` (PASS/FAIL lines) to `<dir>`, then quits. For simulator
screenshots, debug builds also accept `-OwlinkOrientation landscape` or
`-OwlinkOrientation portrait`. Where the simulator can't draw, run the
self-check as a Mac Catalyst build, which uses the same UIKit code (a
local-only project variant; never commit it):

```sh
OWLINK_CATALYST=1 python3 ios/Scripts/gen-xcodeproj.py
xcodebuild -project ios/Owlink.xcodeproj -scheme Owlink -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .dd build
.dd/Build/Products/Debug-maccatalyst/Owlink.app/Contents/MacOS/Owlink -OwlinkSelfCheck /tmp/owlink-shots
python3 ios/Scripts/gen-xcodeproj.py   # back to the committed project
```

**Warning:** launching a Catalyst build registers it with LaunchServices,
and it can become the Mac's default app for a file type (it took `.csv`
on geonosis once). Run it in a test VM, not on a Mac people use; if it ran
on one, unregister it afterwards with
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path>/Owlink.app`
and delete the build.

Catalyst draws the iOS layouts in a Mac window (sizes forced to an
iPhone and an iPad in landscape); the bars look slightly more Mac-like
than on a device.

## What only a real device can show

- The built-in model actually loading and answering (Metal on iOS, memory).
- Apple Intelligence answering (the simulator reports what the host Mac
  allows; a device with Apple Intelligence on is the real test).
- iCloud Drive syncing and conflicts, and other file providers.
- Typing feel with the software keyboard and with a hardware keyboard.
