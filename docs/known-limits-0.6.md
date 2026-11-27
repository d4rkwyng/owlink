# Owlink 0.6.0: known limits

These are review findings that 0.6.0 does not fix. The session and same-file
items were weighed against 0.5.3; the last section records leftovers already
known in 0.5.4. None of these is new in 0.6. Session reliability (e) is
otherwise covered in architecture.md (held buffers, the reopen journal,
durable saves).

## Session recovery (review 27e musts 2-4, review 30e/31e)

1. **A replaced buffer can pass as the current backup at close or quit.** If
   a sync or restore tool swaps an untitled draft's backup for an older
   readable file, and the user then presses ⌘W or ⌘Q without typing, Owlink
   trusts the matching change count. It releases the newer text that was only
   in memory, and reopening brings back the older bytes. 0.5.3 behaves the same
   way (`ClosedTabs.swift`, `AppDelegate.swift` quit path).
2. **A reopen that can't be journaled or saved, followed by a crash, can let
   expiry delete the buffer.** This takes a full disk plus a crash. Reopen a
   dirty tab just before day 30; the reopen journal write and the manifest save
   both fail; the app crashes before any later save succeeds; the next launch
   is past day 30. The entry still carries its old close date and expires.
   0.5.3 has no reopen journal and fails the same way after only a failed
   manifest save. Here 0.6 is equal when both writes fail, and better when only
   one fails.
3. **A journal that can't be looked up at launch is treated as absent.** After
   a crash that leaves a new buffer named only in the journal, a transient
   storage error on the journal's path at launch skips the recovery scan. A
   later save can then prune that buffer. In 0.5.3 the same draft is lost after
   any crash before its first manifest commit, with no storage error needed,
   because 0.5.3 has no journal. 0.6 recovers it whenever the journal can be
   read.

4. **Two Owlink processes on one session folder are not coordinated.** This
   is the same as 0.5.3. Each process prunes against its own snapshot, so a
   second instance launched on purpose (`open -n`, or running a second copy of
   the app) can delete the first's newest backup. Finder and the `cedric`
   command reuse the running app. A single-writer lock and per-instance stores
   were tried in two review rounds (30e, 31e). The review found new loss paths
   in both: restore races around the lock file, a lost-lock quit, and orphan
   cleanup. So 0.6.0 ships the 0.5.3 behaviour.
5. **A save that has to write in place uses plain `fsync`.** When a folder
   doesn't allow a temporary file next to the document, Save As or ⌘S falls
   back to an in-place write. That flush is weaker than the `F_FULLFSYNC` used
   on the normal atomic path. This is older than 0.6.
6. **Reopen Closed Tab (⇧⌘T) on a briefly missing buffer gives up its hold.**
   If a sync or restore has the buffer away at that moment, a later prune can
   unlink it when it comes back. This is older than this round. Launch-time
   retry keeps its hold in the same case.

## Same-file and name validation (Sol / Astra class ii and iii, not fixed)

These need two byte-distinct "canonical twin" names to coexist (default APFS
can't hold them), a crafted direct API call, or inode reuse inside a narrow
race. None writes user text to the wrong file.

- 17v-1 (iii): image-folder containment through a twin. The kernel's
  containment check and the symlink refusal already block it.
- 17v-3 (ii): image publication records keyed by twin spellings. Fixed in
  vfix5.
- 21v-1 (ii): `ImageStore.link(for:)` accepts a non-basename only from a
  direct call. Paste never passes one.
- 21v-2 (ii): a recycled device/inode between publication and link
  validation can approve a link to the replacement bytes. Nothing is
  overwritten.
- 21v-3 (ii part): a cached tab identity race during a Replace in Files
  batch, and twins sharing one buffer.
- 21v-4 (ii): watcher URL conversion picks the wrong twin; an index or UI
  stays stale.
- 21v-5 (ii): the wiki cache folds twin `index.md` paths; backlinks or tags
  go wrong. Notes are untouched.

## Check harness (review 26h, not fixed)

- A local `Scripts/release.sh` run still launches the shipped binary under the
  maintainer's own account (no temp session).
- The `recent` check can add entries to the maintainer's Open Recent list and
  replay a snapshot. It is now opt-in and not run by default.

## Leftovers from 0.5.4 (still open, not worse)

These shipped as known leftovers in 0.5.4. They were checked against the 0.5.4
release notes and history, and against `feat/0.6-speed` at the time of writing:
no fix landed in 0.6.

1. **Undo after Revert keeps the new encoding.** After Revert to Saved or a
   reload, ⌘Z brings the old text back but keeps the new version's encoding
   and BOM. A later save writes those characters with the new encoding. This
   was left open during the 0.5.4 BOM-per-version work (the encoding does not
   follow undo the way line breaks do). No fix commit is in 0.6;
   `FileCommands.swift` and `FileTail.swift` are unchanged vs 0.5.4 / main
   for this path.

2. **UTF-16 Follow appends still go through Foundation.** UTF-8 Follow
   appends at a nonzero offset use `TextCodec.isValidUTF8` and
   `String(decoding:)`, which keep U+FEFF on every macOS. Other encodings,
   including UTF-16, still use `String(data:encoding:)` in
   `FileTail.decodeAppended`. U+FEFF was kept on the machines tried for
   0.5.4; that UTF-16 path is unverified on other macOS versions.
   `Sources/CedricCore/FileTail.swift` is unchanged vs 0.5.4 / main.

3. **Inline prediction is still unverified.** After the 0.5.4 spelling-off
   change, a manual check on an unlocked Apple Intelligence Mac was left
   open: grey inline predictions should still appear and be accepted, and
   Writing Tools should still rewrite a selection, with spelling off. An
   automated probe was inconclusive because the screen was locked. The
   in-app `SpellTypesCheck` still compares property values and menu
   validation, which can pass if the feature itself has stopped working.
   That manual check was not run for 0.5.4 and has not been run for 0.6.
