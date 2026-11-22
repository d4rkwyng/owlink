# Owlink manual

A fast, simple, native text editor for macOS, in the spirit of Notepad++: for
quick work on files, not for projects or compiling. AppKit and TextKit 2, no
dependencies outside Apple's frameworks. Its assistant is Cedric, a small
owl with a monocle (off by default).

Requires macOS 14 or later. Builds as a universal app (Apple silicon and Intel).

The short version is the [README](../README.md).

## Contents

- [Install](#install)
- [Tabs, files and sessions](#tabs-files-and-sessions)
- [Editing](#editing)
- [Spelling and grammar](#spelling-and-grammar)
- [Syntax colouring, themes and settings](#syntax-colouring-themes-and-settings)
- [Markdown and HTML](#markdown-and-html)
- [CSV and TSV as a spreadsheet](#csv-and-tsv-as-a-spreadsheet)
- [PDFs, images, Office files and certificates](#pdfs-images-office-files-and-certificates)
- [Git](#git)
- [Cedric the owl](#cedric-the-owl)
- [Help menu](#help-menu)
- [The cedric command](#the-cedric-command)
- [Privacy and what stays on this Mac](#privacy-and-what-stays-on-this-mac)
- [Building from source](#building-from-source)
- [Releases](#releases)
- [Design notes](#design-notes)
- [Not built yet](#not-built-yet)
- [Built with Claude](#built-with-claude)
- [Licences](#licences)

## Install

With [Homebrew](https://brew.sh):

```sh
brew trust --tap d4rkwyng/tap      # once: newer Homebrew asks you to trust a third-party tap
brew install --cask d4rkwyng/tap/owlink
```

This also puts the `cedric` command on your PATH. Or download
`Owlink-<version>.zip` from [Releases](https://github.com/d4rkwyng/owlink/releases),
open it, and move Owlink to Applications. Owlink doesn't update itself:
`brew upgrade` (or a new download) brings a new version.

## Tabs, files and sessions

### Tabs that come back

Native macOS window tabs. Quitting never asks to
save: every tab, including untitled tabs and unsaved changes, is restored on
the next launch, as Notepad++ does. Unsaved text is autosaved to
`~/Library/Application Support/Cedric/Session/` about 1.5 seconds after you
stop typing, so a crash or power cut loses at most that. Closing a tab
doesn't ask either (hot close): its unsaved text is written to the
session first, and **File › Reopen Closed Tab** (⇧⌘T) brings it back,
unsaved changes and all, even after a quit or a crash. The last 50
closed tabs are remembered (tabs without unsaved text are forgotten
first). A closed tab's unsaved text is kept for 30 days after you close
it, and for at most the 100 most recent such tabs; then it is deleted
(see [Privacy](#privacy-and-what-stays-on-this-mac)).
The first time in a launch that a file tab with unsaved edits is closed,
the tab in front says the file wasn't written, with **Save Now**.
Closing the last document window (text, PDF, image or Office tab) quits Owlink.
It is a close like any other: the tab goes to Reopen Closed Tab (⇧⌘T) with
its unsaved text kept, and the next launch opens an empty Untitled tab.
Quit (⌘Q) with tabs open brings them all back next launch.
Detached previews, Settings and panels don't keep Owlink running.
Settings › General › "Quit when the last window closes" turns this off.

### Fast to open

TextKit 2 lays out only what is on screen; a 10 MB JSON
file opens and is coloured in under 0.1 s, a 50 MB log in about 0.2 s on an
M-series Mac.

### Mac file basics

Save All (⌥⌘S), Revert to Saved (undoable with ⌘Z),
Close Window (⇧⌘W: every tab in the window, each hot-closed; on the last window, then quits, ⇧⌘T has the tabs), and the
system Services in the app menu.

### Float on Top

**Window › Float on Top** keeps that window above your other windows. A
checkmark shows while it is on. It applies to the whole window (every tab
in it), and it comes back when the session is restored. A sheet, and the
command palette, still open above the window.

### Drop a file on the text to open it

**Drop a file on the text to open it** (in its own tab), rather than
pasting its path; dropped text is inserted as before. (On a Markdown
tab a dropped image is linked instead; see [Markdown editing](#markdown-editing).)
A file dropped beside the text (the line numbers, the status bar) opens
too, and a dropped **folder** opens in the [folder sidebar](#folder-sidebar).

### Folder sidebar

**File › Open Folder…** (⇧⌘O), a folder dropped on the Dock icon or on
a window, or `cedric some/folder` shows the folder as a tree at the left
of the editor. **View › Show Folder Sidebar** (⌃⌘1) hides and shows it
again. Until a folder is open nothing is loaded or watched.
**File › Open Enclosing Folder** (⌥⇧⌘O) opens the folder holding the
current tab's file, with the file selected; **File › Reveal in Finder**
shows the file in Finder. Both are off for an untitled tab.

- Click a file to open it in a tab, or to go to its tab if it is open
  (Return does the same). Click a folder's triangle, or select it and
  press → / ←, to expand and collapse it.
- Folders come first, then files in Finder's order. `.git`, `.DS_Store`
  and hidden files don't show; what the folder's `.gitignore` files
  ignore is shown dimmed.
- The tree follows files created, deleted and renamed on disk.
- Right-click: Reveal in Finder, Copy Path, Find in Folder… (Find in
  Files on that folder), Show Hidden Files, Close Folder (or the × at
  the top).
- Drag the divider to resize it. The folder, the folders you expanded
  and the width come back with the session.

### Files changed on disk

**Files changed on disk** reload by themselves when the tab has no unsaved
changes. With unsaved changes, a bar says so (**Reload** / **Keep Mine**),
owl or no owl. **⌘S never overwrites another app's changes:** if the file
changed since Owlink read or saved it, a sheet asks first (**Keep My
Version**, **Reload Theirs** (undoable) or **Compare**).

**A file deleted or moved away** while its tab is open gets a bar when
you come back to the window: "“name” was deleted or moved. Its text is
still here, unsaved." with **Keep Open**, **Save** (writes it back at the
old path), **Save As…** and **Close** (⇧⌘T reopens it). The tab counts as
unsaved, so its text survives a quit. If the file comes back unchanged
the bar goes away; if it comes back changed, you get the changed-on-disk
bar above.

### Encodings and line endings

UTF-8 (with or without BOM), UTF-16 LE/BE,
Latin-1, Windows-1252 and Mac Roman, and LF/CRLF/CR, detected on open
(a file that isn't UTF-8 is read as whichever 8-bit Western encoding
makes sense of its accented letters and quotes) and shown in the status bar,
with menus to convert (applied on save) or reopen with another encoding.
Mixed line endings are shown as such and written as one kind on save.
A file that looks binary (a NUL byte, or many control characters, in
its first 8 KB; never UTF-16) opens with a bar, "This looks like a
binary file", and nothing shown: **Open Anyway** shows it as text,
read-only, with Save off so it can't be rewritten by accident; **Allow
Editing** on the bar makes it an ordinary text tab.

### Print

**Print** (File › Print…, ⌘P; Page Setup…, no shortcut): the text in the
editor's font, dark on white (not the theme's colours), wrapped to the
page, with the file name, date and page numbers; line numbers are an
option in the print panel.

### Careful with files

pipes and devices (`/dev/zero`, a FIFO) are
refused before anything is read; saving through a symbolic link writes
the file it points to and keeps that file's permissions; Export as HTML
and Copy as HTML drop `<script>` and `on…=` handlers; Copy as Rich Text
loads nothing from the network; pasted images never go to an `images`
folder that points outside the document's folder.

## Editing

### The Text menu

The **Text** menu, between Edit and View (as BBEdit's Text menu and
Xcode's Editor menu), holds the commands that change or move through the
text: **Selection** (multiple carets), **Line** (duplicate, move, delete,
Comment Selection, indent, filter lines), **Bookmarks**, **Text Tools**,
**Indentation** (spaces or tabs and the tab width for one tab) and
**Folding**. Edit keeps the clipboard, Find and spelling commands; View
keeps how the window looks. **File › Compare** holds Compare With… (⌥⌘C),
Compare with Last Commit and Next / Previous Difference (⌥⌘↓ / ⌥⌘↑), and
**File › Follow File** (⌥⌘T) reloads a growing log file. Every shortcut is
the same as before 0.4.1; only the menus moved.

### Command palette

**View › Command Palette…** (⇧⌘P) lists every command in the menu bar,
including the Text Tools, Markdown commands and each language and
encoding in the Format menu, for every kind of tab (text, Markdown, PDF,
image). Type part of a command's name and the list narrows as you type:
the letters only have to come in order ("md bold", "fa" for Fold All), and
the menu path counts too. Each row shows its menu path and its shortcut,
so the palette also teaches the keys. ↑/↓ move, Return runs the command,
Esc (or a click elsewhere, or ⇧⌘P again) closes it. The five commands you
ran from it most recently come first, for as long as Owlink stays open.

Commands that can't run in the current tab are listed dimmed, as in the
menu, and Return on one does nothing. The list is read from the menus each
time the palette opens, so new commands appear in it with nothing to set
up; it leaves out the palette itself, the Window menu's list of windows
and the Services menu. Nothing about it runs until you open it. With
VoiceOver, the number of matching commands is read as you type, and the
selected command (with its shortcut and menu) as you move.

### Open Quickly

**File › Open Quickly…** (⌥⌘O) opens the palette for files: with a folder
open in the sidebar, type part of a file's name and its files are listed
by fuzzy match, as in Xcode or VS Code. A match in the name ranks above a
match that needs the folders, a name's word starts ("fs" for
FolderSidebar.swift) and its beginning rank high, and on a tie the shorter
name and the shallower file come first. Type a `/` to match the whole path
("app/del"). Return opens the file in a tab (or selects its tab). The list
follows the sidebar: hidden files only with Show Hidden Files, and nothing
the folder's `.gitignore` files ignore. The folder is indexed in the
background the first time you use it there (up to 20,000 files, nearest
the top first) and kept current as files come and go.

The current Markdown document's headings follow the files; start the query
with `#` to search only them, and Return jumps to the heading. Start it
with `>` for the menu commands. ⌥⌘O isn't Xcode's ⇧⌘O (that is Open
Folder… here) or ⌘P (Print…).

Page Setup… gave up ⇧⌘P for it (VS Code, iA Writer and Drafts use ⇧⌘P for
their palettes); it has no shortcut now.

### Context Bar

**View › Show Context Bar** shows one thin row of buttons above the text,
for the kinds of file that have a set; for code, plain text and the other
types there is no bar and no empty row. It is on by default (**View › Hide
Context Bar** puts it away, and Owlink remembers that), and one switch
covers every tab. While it is off nothing about it is built, and
typing is as fast with it shown as hidden.

Markdown's set, left to right: a heading pull-down (Body, Heading 1,
Heading 2, Heading 3), Bold, Italic, Strikethrough, Inline Code, Link,
Bulleted List, Numbered List, Checkbox, Quote, Code Block, Insert Table
and Image Link (see [Markdown editing](#markdown-editing)), and at the far
end a preview toggle (an eye) that lights up while the preview shows. The
icons take their colour from the theme and stand out from the bar at
least 3:1 in every theme.

Every button runs the Format › Markdown or View command with the same
name: the same thing happens from the bar, the menu, the shortcut and the
[command palette](#command-palette), a button is dimmed when the menu item
is, and each is one undo step. Hold the pointer over a button for its name
and shortcut. VoiceOver reads each button by its command's name (and the
preview toggle as on or off), and with Full Keyboard Access on the
buttons are in the window's keyboard focus order like any other. The bar
follows the editor's theme, and in right-to-left languages it mirrors.

### Find and replace

**Find and replace** in the current document, with regular expressions
(ICU syntax, `$1` in replacements), match case and whole word; ⌘F, ⌥⌘F,
⌘G / ⇧⌘G, ⌘E. Replace All is one undo step.

### Find and replace in files

**Edit › Find in Files…** (⇧⌘F) searches a folder (Include and Exclude
take patterns such as `*.swift`; **Respect .gitignore**, on by default,
skips what the folder's `.gitignore` files ignore). Results are grouped
by file; click one to open the file with the match selected. Binary
files and files over 20 MB are skipped.

**Edit › Replace in Files…** (⌥⇧⌘F) opens the same panel with a
Replace field (`$1` for a regex group, as in the find bar):

1. **Preview Replace…** (or Return in the Replace field) lists every
   change as before → after. Nothing is changed yet. Uncheck a file or a
   single match to leave it out. The summary says how many replacements
   in how many files, and which files are skipped and why (binary, over
   20 MB, mixed line endings, changed since the search…).
2. **Replace All** changes the checked matches. A file open in a tab is
   changed in the tab (one ⌘Z there, not saved). The other files are
   written in the background, with a progress bar, each in its own
   encoding and line endings and keeping its permissions.
3. **Undo Replace** in the panel, or **Edit › Undo Replace in Files**,
   puts the last replace back byte for byte. A file edited since is left
   alone and listed, and so is one that has become read-only or whose
   backup copy can't be read (the reason is given: missing, permission
   denied, or not matching the original); those files stay as the
   replace left them and Undo stays available to try again. With the
   panel hidden, the undo's progress and result show in a bar at the top
   of the tab. The command undoes only the most recent replace, and only
   until you quit Owlink.

Replace All never writes read-only files, anything inside a `.git`
folder (or a `.git` file), whatever the Exclude field says, or a file
whose encoding Owlink had to guess as Latin-1, Windows-1252 or Mac Roman
when the replacement has accented or other non-ASCII text, or the file
also holds UTF-8 text ("encoding uncertain": it may be UTF-8 with one
stray byte). Those are listed as skipped, with why. A replaced file gets
a new modification date, so backup and build tools see the change.

Before Replace All writes a file, Owlink copies the original to
`~/Library/Application Support/Cedric/ReplaceUndo/<id>/`, one folder per
replace (only your user account can read it), with a `manifest.json`
that says which copy belongs to which file. These copies stay after you
quit, so you can recover a file by hand from them. Files changed in a
tab aren't written, so they aren't copied: ⌘Z in the tab undoes them.
Owlink keeps the copies of the last 5 replaces. Each time you replace
again, and each time Owlink starts, it deletes the older ones and any
older than 7 days.

Files with mixed line endings are skipped: open them and use the find
bar there.

### Multiple carets and column selection

| To | Do |
|---|---|
| Select a column | ⌥-drag (straight down makes a column of carets) |
| Add or remove a caret | ⌘-click |
| Add a caret on the line above / below | ⌃⇧↑ / ⌃⇧↓ |
| Select the next match of the selection | ⌘D (first press: the word at the caret) |
| Select every match | ⌃⌘G |
| Go back to one caret | ⎋ |

The menu items are in Text › Selection. Typing, Delete, Return (with
indent), Tab, auto-closed brackets and quotes, copy, cut, paste, the
arrow keys and ⇧-arrows work at every caret. Pasting as many lines as
there are carets puts one line at each. The status bar shows the number
of carets. One ⌘Z undoes one edit at all of them.

Input methods and dead keys (⌥E then E for é) compose at the main caret,
and the result goes in at every caret. VoiceOver follows the main caret.

### Code folding

Hover over the line numbers: a ▾ appears beside each line that starts a
block. Click it to fold the block; the line shows ▸ and a "⋯ 12 lines"
pill, and the numbers of the hidden lines are skipped. Click the ▸ or the
pill to unfold.

| To | Do |
|---|---|
| Fold the block at (or around) the caret | ⌥⌘← (Text › Folding › Fold) |
| Unfold the caret line's block | ⌥⌘→ |
| Fold every block | ⌥⇧⌘← |
| Unfold everything | ⌥⇧⌘→ |
| Show only the outer levels | Text › Folding › Fold to Level 1, 2 or 3 |

What folds:

- **Brackets** `{ }`, `[ ]`, `( )` in Swift, JavaScript, TypeScript, C,
  CSS, JSON and PowerShell, from the line that opens to the line that
  closes (the closing line stays). Brackets inside strings and comments
  don't count.
- **Block comments** (`/* … */`) over several lines.
- **Indentation** in Python, YAML, shell scripts, Ruby and SQL: a line and
  the deeper-indented lines under it.
- **Sections** in INI and TOML: each `[section]` to the next.
- **Headings** in Markdown: each heading down to the next heading of the
  same or a higher level. A `#` line in fenced code isn't a heading.
- Plain text, CSV, diffs, batch files and .reg files don't fold.

Folded text is only hidden: the file is unchanged, and save, undo,
print, export and copy see all of it (copying across a fold copies the
hidden lines). The arrow keys step over a fold. Find, Go to Line, a
bookmark, the outline or a caret that lands inside a fold opens it, and
so does typing in it or pressing Return at the end of its first line.
Folds are kept with the session. Large-document mode turns folding off.

### Split view

View › Split Editor (⌃⌘\\) shows the document in two panes, one above
the other, so you can read one part while you edit another. Both panes
are the same document: what you type in one shows in the other at once,
and one ⌘Z undoes it from either pane. Each pane scrolls and keeps its own
caret and selection.

| To | Do |
|---|---|
| Split, or close the split | ⌃⌘\\ (View › Split Editor), or Split Editor / Close Split in the text's context menu |
| Panes side by side, or back one above the other | View › Split Side by Side, or the context menu |
| Go to the other pane | View › Move Focus to Other Pane, or click in it |
| Resize the panes | Drag the line between them |

Commands act on the pane you're in (the last one you clicked or typed
in, also while the find bar has the focus): Find and Replace, Go to Line,
multiple carets, bookmarks, folding, the Markdown and line commands, and
the status bar's line and column. Folds are the document's, so folding in
one pane folds in both. Spelling and grammar underlines and Cedric the
owl stay with the top (or left) pane. The preview, Find in Files and the
folder sidebar dock around both panes as they do around one.

The split, its orientation and size, the second pane's place and which
pane had the focus come back with the session. Closing the split frees
the second pane; a tab you never split costs nothing extra.

### Highlight occurrences

other occurrences of the selection, or of the
word under the caret, are tinted on screen (View › Highlight
Occurrences). **Mark All** (⌃⌘M) marks every occurrence until Clear
Marks (⌃⇧⌘M), with a count in the status bar. Only the visible text is
searched, so typing stays fast in big files.

### Line operations

**Line operations** (Text › Line): Duplicate Line (⇧⌘D), Move Line Up /
Down (⌃⌘↑ / ⌃⌘↓), Delete Line (⇧⌘K), Comment Selection (⌘/, with the
language's own comment marker: `//`, `#`, `/* */` or `<!-- -->`). Each
works on every line the selection touches and is one undo step. ⌘X with
nothing selected cuts the whole line.

### Indent and outdent

Tab and ⇧Tab on a selection of several lines
(or Text › Line › Indent ⌘] / Outdent ⌘[) shift every line by one step,
as one undo step. Each tab follows the file's own indentation (tabs, or
2, 3, 4 or 8 spaces, read from its first lines), else the default in
Settings; Text › Indentation picks spaces or tabs and the tab width for
one tab (kept with the session) and converts the whole file between
them. Where spaces were chosen (the file's own, the tab's, or a default
saved in Settings), Tab inserts spaces to the next tab stop; otherwise
it types a tab character, as before. **YAML always indents with
spaces** (2, or the file's own width; the YAML spec forbids tabs), and
**Python with 4 spaces** unless the file uses tabs or tabs are the
default saved in Settings.

### Auto-indent and pairing

Return keeps the line's indent, one step
more after `{` `[` `(` (and `:` in Python and YAML); Return between a
pair puts the closer on its own line. In Python, Return after
`return`, `pass`, `break`, `continue` or `raise` steps one level out,
and typing the `:` of `else`, `elif`, `except` or `finally` lines the
clause up with its `if`, `try`, `for` or `while`. In YAML, Return
continues a `- ` item (an empty one ends the list), and after
`- key: value` lines up under the key. In code, brackets and quotes close
themselves (no `'` in Swift or JSON), typing the closer steps over it
(a quote only over one that pairing typed), Backspace between a pair
deletes both, and typing one with a selection wraps it (Edit ›
Auto-Close Brackets and Quotes; never in plain text or Markdown). The
bracket next to the caret and its partner are boxed.

### Bookmarks

**Bookmarks** (Text › Bookmarks, as in Notepad++): Bookmark Line (⌘F2,
or click a line number; it reads Remove Bookmark on a bookmarked line), Next / Previous Bookmark (F2 / ⇧F2, wrapping),
Bookmark All Matches (⌥⌘F2: every line matching the find bar's search,
or the selection or word under the caret), Clear Bookmarks (⇧⌘F2).
Bookmarks stay on their lines as you edit (Replace All, Comment Selection
and Text Tools included: a line whose text survives keeps its
bookmark), move with Move Line (and back with Undo), and are kept with
the session. Copy Bookmarked Lines and Delete Bookmarked Lines
act on them all.

### Filter lines

**Filter lines** (Text › Line › Keep Lines Matching… / Delete Lines
Matching…): plain text or a regular expression, with or without case,
as one undo step; bookmarks on the lines that stay follow them.

### Go to line

**Go to line** (⌘L, `42` or `42:7`), line numbers, current-line highlight,
show invisibles (⌥⌘I), wrap lines (⌥⌘Z).

### Word, line and character counts

**Word, line and character counts** in the status bar, of the
selection when there is one (characters are Unicode scalars). Documents
over a million characters show lines only, so typing never waits on a
count; over 50,000 they are counted when typing pauses, in the background.

How words are counted, in every kind of file:

- A word is a run of letters and digits; an apostrophe or hyphen splits
  it (`don't` is two words) and `_` doesn't (`snake_case` is one).
- Chinese and Japanese characters (Han and kana) are one word each, as
  word processors count them; Korean is counted by its spaces.
- Emoji and symbols are characters, not words.
- Markdown's markers (`#`, `*`, `_`, `>`, `-`, `|`, brackets, backticks,
  a `___` rule) are never words. Text you typed counts as written: the
  words in a link's address, in code, and the `x` of a ticked `- [x]`
  box are counted too.
- A Windows line ending (CR LF) is one character.

### Stats and a word goal

**Click the word count** in the status bar (or choose **View › Show
Statistics**, also in the command palette; with Full Keyboard Access on,
Tab to the word count and press Space) for the stats popover: the
document's words, characters, lines and reading time, and the same for
the selection beside them when there is one. Reading time is at 238 words
a minute, the average for silent reading of non-fiction (Brysbaert, 2019).
The numbers follow your typing while the popover is open; click outside
it to close it.

**Word goal:** type a number in the popover's Word goal field and press
Return. The ring fills as you write (green once you reach it), with
"279 of 500 words (55 %)" beside it. The goal belongs to the file: it
comes back after a quit, and when you open the file again later, also in
a new tab. It is kept in Owlink's session, never written into the file.
Empty the field to clear it. An untitled tab keeps its own goal, and takes
it to the file when you save it.

### Daily word target

The same popover has a **Daily target**, off until you set one. Type a
number and press Return (empty, or 0, clears it). The second ring fills
with the words you write today, in every document, not with the length of
the file: opening a file does not count the words already in it. Deleting
text takes those words back, and the day never goes below zero. It resets
at midnight on this Mac. Owlink updates the count when you save, when you
close the tab, and when you pause typing, so typing stays as fast with a
target as without one. The target and the count are kept for Owlink, not
written into any file.

### Writing Mode

**View › Writing Mode** has two switches for writing prose, both off by
default. Each is for the tab you are in (other tabs keep theirs), and comes
back with the session. They are in the [command palette](#command-palette)
too.

- **Typewriter Scrolling** keeps the line you are typing on at the middle
  of the window: the text scrolls up instead of the caret moving down.
  Space is added below the last line so it can reach the middle too.
  Clicking a line glides it to the middle; with **Reduce Motion** on
  (System Settings › Accessibility › Display) it moves there at once.
- **Focus** dims everything except the paragraph you are in, so the rest
  of the text stays out of the way. Choose **Focus on Paragraph** (lines
  between blank lines) or **Focus on Sentence** (just the sentence at the
  caret; "Dr." or "3.5" don't end a sentence) in the same menu; the choice
  is for every tab. Focus changes only how the text is drawn: nothing in
  the file, undo or Find changes.

Typing is as fast with either on as with both off. Like syntax colouring,
both pause in large-document mode (a line over 20,000 characters, or a
file over about 25 MB): the bar above the text says "…the owl and Writing
Mode are paused for speed", the menu items stay ticked, and they work again
after **Turn On Anyway** or once the document isn't large.

### Readable width

**View › Readable Width** keeps the text in a centred column about 72
characters wide, as in iA Writer, however wide the window is; a window
narrower than that wraps as usual. It is off until you turn it on, for
every kind of file. The menu item switches it for the current tab and
keeps that choice. Settings › Writing › Readable Width (unchecked) is the
default for tabs that have not chosen. The width is the number next to
that checkbox (60–100 characters). It needs View › Wrap Lines. With it
on, line numbers, fold triangles and git bars sit just to the left of the
text, and Typewriter Scrolling and Focus work the same in the column.
Typing is as fast with it on: the column only moves when the window, the
font or the setting changes.

### Prose font

**Settings › Writing › Use a prose font for Markdown and plain text**
(off by default, so nothing changes until you turn it on) sets Markdown
and plain-text tabs in a font of their own: the system font (SF Pro) by
default, New York, or any installed family, at its own size (15 pt by
default). Code tabs keep the monospaced font from Settings › General, and
a tab switches font when its language changes. Zoom (⌘+ / ⌘− / ⌘0, the
status bar's percentage) scales both fonts by the same ratio. A large
document (large-document mode: a line over 20,000 characters, or a file
over about 25 MB) keeps the monospaced font, even after Turn On Anyway:
a proportional font made typing on a very long line noticeably slower.

Line numbers, folding, git bars, Readable Width, Writing Mode's Focus and
Typewriter Scrolling, printing and split view work the same with it.
Readable Width counts a proportional font's characters by its average
lowercase letter, so the column still holds about the number of
characters set. Things that depend on columns:

- **Ln, Col** in the status bar counts characters, as before; it doesn't
  depend on the font.
- **⌥-drag** (column selection) selects the rectangle you drag, by
  position, so each row's selection starts and ends under the pointer
  rather than at the same character.
- **Add Caret Above / Below** (⌃⇧↑ / ⌃⇧↓) keeps the character column, as
  in a monospaced font; in a proportional font the new caret need not sit
  directly above or below.
- Owlink draws no indentation guides, so there are none to misalign.

## Spelling and grammar

### Fix Typos…

**Fix Typos…** (Edit › Spelling and Grammar, ⌥⌘;, or **Fix Typos…** in
the owl's "Fix 3 typos?"): steps through the misspelled words one at a
time, from the caret to the end and round from the top, in a small panel
beside each word with the checker's suggestions (the first picked),
**Change**, **Change All**, **Skip**, **Ignore All** (this document),
**Learn Word** and **Done**, and "3 of 12". Return changes, Tab or ⌘→
skips, Esc is done. Each change is one undo step (Change All too). Only
the words spell check would mark: prose in Plain Text and Markdown,
comments and strings in code, never URLs or paths. Big files are
checked a chunk at a time, in large mode only as far as the next word.

### Grammar in prose

**Grammar in prose** (Settings › Writing › "Check grammar in prose", on by
default; also Edit › Spelling and Grammar): macOS's own grammar checker
(local, nothing sent anywhere) looks at documents written for people,
never at code, data or logs. A document counts when it is Plain Text or
Markdown and the text in view reads as sentences (words, function words
like "the" and "and", sentence punctuation, few symbols, few lines that
look like code, config, a log or a CSV row; Markdown's code, front
matter, tables, inline code and URLs are left out). A short bullet list
such as a shopping list doesn't count; a list of whole sentences does.
After typing pauses the text in view (at most 8 KB) is checked in the
background, in the checker's language (yours, or detected if you have
"Automatic by Language"); findings get a green dotted underline, and a
right-click on one shows the checker's note and its suggestion (Change
to, Ignore Grammar). With the owl on he offers one at a time, e.g.
"Grammar: ‘a’ → ‘an’?", with **Fix it** (one undo step), **Fix
Grammar…** (step through them in a small panel: Change, Skip, Done, "2
of 5"), **Not in This File** and **Don't show again**; never while you
type (he waits for his usual 3-second pause), and at most one grammar
bubble every 10 minutes unless you click the owl and choose **Grammar
Hint**. Never in large mode or in files over 1 MB. Meeting notes with
"Date:" and "Status:" lines stay Plain Text instead of being taken for
YAML. The checker
catches only what macOS's catches ("a elephant", doubled words, some
agreement errors); it misses many others, such as "Their going too the
store".
With Ask Cedric on and an AI engine ready, **Check Grammar with
AI** (Edit › Spelling and Grammar, or the owl's popover) asks the model
about the prose in view; what it finds (only exact words from the text,
a few words at a time) gets the same underline, **Fix it** and **Fix
Grammar…**. It runs on its own only where automatic AI checks are on
(never on Intel Macs by default); the macOS checker stays on as well.

## Syntax colouring, themes and settings

### Syntax colouring

**Syntax colouring** for Swift, Python, JavaScript, TypeScript, JSON, YAML,
Markdown, HTML (with embedded `<script>` and `<style>`), XML (with CDATA;
`.xml`, `.plist` and friends, no longer coloured as HTML), CSS, shell,
C/C++/Objective-C, Ruby, SQL, diff/patch, INI/TOML/.env/.properties,
PowerShell (`.ps1` `.psm1` `.psd1`: comments and comment-based help,
literal, expandable and here-strings with `$var` and nested `$( … )`
coloured inside, variables, Verb-Noun cmdlets, `-Parameters`, `-eq`-style
operators, `[types]` and `[Attributes()]`, `1KB` numbers), Windows batch
files (`.bat` `.cmd`: `REM`/`::`, labels, `%var%`, `!var!`, `%%i`) and
registry exports (`.reg`) (CSV and TSV open as plain text with a grid preview). Only the visible lines plus a margin are coloured, so
big files stay fast. The language comes from the file extension, a `#!` line,
or, for pasted text in an untitled tab, from the content; the status bar
menu overrides it.

### Themes

System (light or dark with macOS), Light, Dark, Tankard (deep
purple and amber) and Dracula, the same set as Tankard. Every theme's text
colours meet WCAG AA contrast (4.5:1), checked by a test. SF Mono by
default, or any installed fixed-pitch font (Markdown and plain text can
have their own *prose font*, below); ⌘+ / ⌘− / ⌘0 zoom. The zoom
in the status bar ("110%") is a menu too: Zoom In, Zoom Out, Actual Size
and 75 % to 200 %. With the preview docked beside the editor, the status
bar's items stay under the editor (both panes of a split).

### Settings

**Settings** (Owlink › Settings…, ⌘,) is one window with four tabs in
its toolbar. Every control takes effect the moment you change it; there
is no Save or Cancel. A text field applies when you press Return or
leave it. Settings opens on the tab you last used.

- **General**: theme, font and size, whether closing the last window
  quits, and Default editor for… (below).
- **Editor**: the default indentation for new files (Text ›
  Indentation changes one tab), Wrap lines, Show invisibles, Show line
  numbers, Highlight occurrences, Auto-close brackets and quotes, and git
  changes in the gutter.
- **Writing**: the prose font (below), the readable width's column, Check spelling while typing,
  Check grammar in prose, and Style Check with its Also flag and Never
  flag lists.
- **Cedric**: Show Cedric, Ask Cedric, Style tips in code, and the
  Cedric AI settings (see *The owl and his hints*). Cedric › Cedric AI
  Settings… opens this tab.

Wrap lines, invisibles, line numbers and highlight occurrences are also
in the View menu, and auto-close brackets, spelling while typing and
grammar in the Edit menu. The menu item and the checkbox are the same
setting: change either and the other shows it (all remembered, for every
tab).

Each tab is a toolbar button with a name and an icon. Tab moves
through a tab's text fields (and, with keyboard navigation on in System
Settings, every control); VoiceOver reads each tab and control by its
name.

### File types, default editor and document icons

**Settings › General › Default editor for…** lists the text file types Owlink has
its own icons for, with the app that opens each one now: plain text
(.txt), Markdown, JSON, YAML, Swift, Python, JavaScript, TypeScript
(.tsx), shell scripts (.sh, .zsh, .bash), logs, CSV, XML, CSS, TOML, INI,
SQL and PowerShell.

- **Tick a type** to make Owlink the app that opens it when you
  double-click such a file. On macOS 26 and later, macOS asks you to
  confirm ("Do you want all documents with the extension ".py" to open
  with "Owlink", or to keep using "TextEdit"?"); if you keep the other
  app, nothing changes and Settings says so. macOS 15 changes it without
  asking.
- **Untick it** to give the type back to the app Owlink took it from. If
  Owlink doesn't know that app (Owlink already opened the type), choose
  one in Finder: select a file, File › Get Info, Open with, pick the app,
  **Change All…**.
- **Use Owlink for All Text Files** goes through every type in the list,
  one macOS prompt each on macOS 26 and later (shell scripts ask for .sh,
  .zsh and .bash separately), and stops at the first one you decline.
- **HTML is not in the list.** macOS treats the app for HTML files as your
  web browser and asks whether Owlink should become it. Use Get Info ›
  Change All on an .html file if you want that anyway.
- **.ts files** are MPEG video to macOS before they are TypeScript, so the
  TypeScript row covers .tsx files. For .ts, use Get Info › Change All on
  one.

Owlink never makes itself the default by being installed, updated or
opened, and Settings only reads the defaults until you click. One thing
predates 0.3.0 and is unchanged: on a Mac where nothing but TextEdit
opens text, Markdown, JSON and YAML files open in Owlink once it's
installed, because Owlink names those types and TextEdit only claims
"text". (On macOS 15, where .md files opened in nothing before, they now
open in Owlink for the same reason.) The labelled types never open in Owlink unless you choose it.
Changes you make in Get Info show in Settings the next time its window
comes to the front.

**Document icons.** Files whose default app you set to Owlink show in
Finder as a white page with Cedric and a coral label with the type (TXT,
MD, JSON, YAML, SWIFT, PY, JS, TS, SH, LOG, CSV, XML, HTML, CSS, TOML,
INI, SQL, PS1). Finder shows them:

- only for types you chose Owlink for, in Settings or with Get Info ›
  Change All. A type that opens in Owlink without your choice (Markdown,
  JSON, YAML on a Mac with no other editor) shows the page and owl
  without a label until you choose it; **Use Owlink for All Text Files**
  does that for every type;
- when Finder isn't showing a picture of the file's contents instead: in
  icon view, View › Show View Options › **Show icon preview** draws the
  text itself for many text files. Untick it to see the type icons;
- on macOS 14, 15, 26 and later alike: they are plain `.icns` files named
  in Owlink's Info.plist (`CFBundleTypeIconFile`), not composed by macOS.

macOS caches file icons. A file Finder has already drawn may keep its old
icon after a change for a while, even after you relaunch Finder; new
files and the next restart show the new one.

**Types macOS doesn't know.** macOS has no type for TypeScript, TOML,
INI, SQL or PowerShell files on its own (Xcode adds some when installed),
nor, before macOS 26, for Markdown, so Owlink declares them
(`UTImportedTypeDeclarations`, with the identifiers Xcode and macOS 26
use): .tsx/.ts, .toml, .ini, .sql, .ps1/.psm1/.psd1, .md/.markdown.
Being text, they then open in TextEdit until you choose another app,
where before they opened in nothing.

## Markdown and HTML

### Live preview

**Live preview** for Markdown and HTML, side by side (View › Preview ›
Show Preview, ⌥⌘P). JavaScript and network access in the preview are **off** by default
and can be turned on per tab (View menu, or the preview bar). Turn them on
only for pages you trust: with both on, the page's script can send what it
shows anywhere. With JavaScript on, the page can load only images, fonts
and CSS from the document's folder, never other files or hidden ones
(`.env`, `.git`). Both switch off again when the file is reloaded from
disk (say after a `git pull`), so new content never inherits them. A compact
**preview bar** across the top of the preview (and of a detached
preview's window) has Refresh, Sync Scrolling on/off, Zoom − / +,
Export ▸ HTML / PDF (Markdown), Allow JavaScript, Allow Network and
Detach / Attach; for CSV, the row count and Unsort (back to file order).
It follows the theme; every button has a tooltip and a VoiceOver label.
The same actions are in the **View › Preview** menu, enabled when the
bar's button is: Refresh Preview (⌥⌘R), Sync Scrolling, Zoom In Preview
(⌥⌘=), Zoom Out Preview (⌥⌘−), Restore File Order (CSV), Export as HTML
/ PDF, Allow JavaScript, Allow Network and Detach / Attach Preview.
A link in the preview never
launches anything: web and mail links open only after you confirm the
full URL, a text file in the document's folder opens in a tab, any
other file (or one outside the folder) is shown in Finder, and other
schemes are ignored. The Markdown preview doesn't
flicker or jump: it is rendered in the background (a 1 MB file costs the
main thread about a millisecond per update), and only the blocks that
changed are swapped into the page, so it keeps its place and its images.
Scrolling either side scrolls the other to the same source line (by
block, list item and quote). Relative images load from the document's
folder (and only from there), and a link to a relative `.md` (or other
text) file opens it in an Owlink tab. The renderer follows CommonMark's
emphasis rules (`**bold *mix***` nests properly) and knows reference
links, footnotes (`[^1]`), GitHub alerts (`> [!NOTE]`, `[!TIP]`,
`[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), task lists (disabled
checkboxes) and YAML frontmatter, which shows as a small metadata table
(and is coloured as YAML in the editor). It also reads Obsidian's syntax:
`[[note]]`, `[[note|alias]]` and `[[note#Heading]]` link to notes in the
vault (the sidebar folder, else the folder holding `.obsidian/`) and open
them in a tab, `![[image.png|300]]` shows the image, `![[note#Heading]]`
quotes that part of the note, and callouts (`> [!info]-`), `==highlight==`,
`%%comments%%` and `#tags` show as in Obsidian. Site-root images
(`/images/logo.webp`, as Hugo, Jekyll or Quartz write them) load from the site's
folder on disk (`static/`, `public/`, `quartz/static/` and `content/`), never the network. Fenced code blocks are
coloured by their language (```` ```swift ````, `py`, `js`, `bash`, …)
both in the editor and in the preview, by Owlink's own tokenizers and
the theme's colours (no JavaScript highlighter). **Detach Preview** (View menu, ⇧⌥⌘P,
or Detach on the preview bar) moves it into its own resizable
window, "notes.md — Preview", still updating as you type; it stays
with its own document whichever tab is in front, and closes with that
tab. Attach Preview docks it again; closing its window closes the
preview. A detached preview and its window's frame are kept with the
session (restored just after the window first shows). A docked Markdown
preview is kept too, at the width you left it, and comes back the same
way. A session saved before that leaves the preview closed.

### Markdown editing

- **Lists:** Return continues a `-`, `*`, `+`, `1.` or `1)` list (and
  one in a `> ` block quote) with the same indent; the number goes up
  and a task item `- [x]` continues as `- [ ]`. Return on an empty item
  outdents it if it is nested, else ends the list. Tab and ⇧Tab in a
  list item indent or outdent the item with its sub-items, by the
  parent's content width (2 under `- `, 3 under `1. `). Ordered lists
  renumber after Return, Tab and ⇧Tab (a list written `1. 1. 1.` stays
  so; a nested list starts at 1). Each is one undo step; nothing
  happens inside fenced code or while an input method is composing.
- **Format › Markdown:** Bold ⌘B, Italic ⌘I, Strikethrough ⇧⌘X,
  Inline Code ⌃\` and Link ⌘K wrap the selection, or with no
  selection put the pair in with the caret between. Each takes its
  markers off when they are already there (around or inside the
  selection, or around the caret's word), so ⌘I on `*word*` doesn't
  stack another pair; Bold over text that has bold inside it merges
  them (`a **b** c` becomes `**a b c**`). ⌘K turns the selection into `[text](|)` with the
  caret in the URL, or uses the URL on the clipboard; a selected URL
  becomes `[](url)`; in a link it unlinks. Only in Markdown tabs.
- **Headings:** Format › Markdown › Heading 1, Heading 2 and Heading 3
  (⌘1, ⌘2, ⌘3) make the caret's line, or every selected line, a heading
  of that level; pressed again on such a line it goes back to body text,
  and on a heading of another level it changes the level (`# ` to `## `,
  never `## # `). Body takes the heading off. One undo step.
- **Lists, quotes and code blocks:** Format › Markdown › Bulleted List
  and Numbered List turn the selected lines (or the caret's line) into a
  list, after any indent or `> `; blank lines between them are left as
  they are. When every line is already that kind of list, the markers
  (and checkboxes) come off instead. A bulleted list keeps its `*` or `+`
  if it had one; a numbered list counts from 1 at each indent level, or
  on from a numbered item just above, and keeps `1)` if the list used it.
  Quote puts `> ` in front of the lines (a blank line between them gets a
  bare `>`), or takes one `>` off when they are all quoted. Code Block
  puts ```` ``` ```` lines above and below them (on an empty line, an
  empty block with the caret inside); with the caret or selection inside
  a fenced block, or the whole block selected, its fence lines go and the
  code stays. Each is one undo step; nothing changes inside fenced code
  except with Code Block.
- **Tables and images:** Format › Markdown › Insert Table puts a 3-column
  table (a header row and two empty rows) below the caret's line, with a
  blank line before and after it, and the caret in the first cell; Tab
  then moves through the cells and lines them up (see Tables below).
  Image Link turns the selection into `![selection]()` with the caret
  between the parentheses (or uses a URL on the clipboard), a selected
  URL into `![](url)`, and with the caret in an image it takes the image
  markup off and leaves its alt text.
- **Checkboxes:** Format › Markdown › Checkbox (⌘↩) checks
  or unchecks `- [ ]` / `- [x]` on the caret's line or every selected
  line, adds a box to a list item without one, and turns a plain line
  into `- [ ] line`. One undo step.
- **Tables:** in a GFM table, Tab and ⇧Tab move to the next or
  previous cell (selecting its text) and line up the whole table's
  pipes; Tab past the last cell adds a row, and Tab after a lone
  `| a | b |` header builds the `| --- |` row. Return in a row goes to
  the same cell in the row below (adding one at the end); Return in an
  empty last row ends the table. Format › Markdown › Format Table
  lines it up without moving. Widths count East Asian wide characters
  and emoji as two columns (the CJK fallback font isn't exactly twice
  SF Mono's width, so on screen those rows can be a pixel or two off);
  alignment colons are kept. Tables in fenced code, and tables over
  2,000 lines, are left alone.
- **Smart paste:** a URL pasted over a selection makes
  `[selection](url)` (not in code). An image pasted or dropped on a
  Markdown tab (an image file, or a picture such as a screenshot on the
  clipboard) is copied into an `images` folder next to the document and
  goes in as `![](images/name.png)`; an image already inside the
  document's folder is linked where it is, not copied. An untitled tab
  has no folder yet: it inserts nothing and offers Save As. Undo takes
  the link out but leaves the copied file. Other dropped files still
  open in their own tabs, and in other languages a dropped image opens
  as before.

### Markdown outline

**Markdown outline** (View › Show Outline, ⌃⌘O; for a PowerShell
script it lists the functions, filters, classes and enums): the document's
headings (`#` and underlined ones, never a `#` inside fenced code or
frontmatter), indented by level, at the left of the text. Click one to
jump there; the heading the caret is under stays selected; the filter
field narrows the list. **Go to Heading…** (Edit menu, ⇧⌘J) opens it
with the filter focused: type, ↑/↓, Return to jump (Esc goes back), and
it puts itself away again. Built the first time it is shown and updated
in the background when typing pauses (in large mode only when opened,
up to 5,000 headings).

### Markdown export and copy

File › Export as HTML… writes a standalone
page (no script), and File › Export as PDF… a paginated PDF (cut between
blocks), both rendered as the preview renders them in a light,
theme-neutral style whatever the editor's theme. Wikilinks and embeds in
an export point at their files by a path relative to the document (an
unresolved wikilink is plain text), and embedded notes are written out in
place. Edit › Copy as HTML puts
the rendered HTML of the selection (or the whole document) on the
clipboard as text; Copy as Rich Text puts it there as rich text (RTF and
HTML) for Mail, Notes or a word processor.

## CSV and TSV as a spreadsheet

the preview (⌥⌘P) of a `.csv`, `.tsv`
or `.psv` file is a read-only grid: the first line is the header, row
numbers stay at the left, columns resize, and a click on a header sorts
the grid (never the text). Clicking a cell puts the caret in that field.
Quoted fields with commas, quotes and line breaks are read as RFC 4180
says; the separator (comma, tab, semicolon or pipe) is detected from
the first lines (quotes, blank lines and decimal commas such as
`1,5;2,3` taken into account), `.tsv` means tab, and an Excel `sep=;`
first line is honoured. Spaces after the separator (`name, age, city`,
`x, "a, b"`) are padding, not data, as Python's `skipinitialspace`
reads them; spaces inside quotes and in TSV are kept. Pipe tables
(`| a | b |`, with a `|---|` rule) show without their empty edge columns. It updates as you type, parses
off the main thread, and shows the first 50,000 rows of a longer file
(with a note). A quote that never closes doesn't swallow the rest of
the file: the grid ends that field at its line and an orange note says
"Unclosed quote on line N" (the text is untouched). It detaches like
the other previews.

## PDFs, images, Office files and certificates

### PDFs open in a viewer tab

**PDFs open in a viewer tab** (read-only, PDFKit), from File › Open, a
drop on a window or the Dock icon, `cedric file.pdf` (`file.pdf:3` for
page 3), Open Recent or Finder's Open With (Owlink is registered as an
alternate PDF viewer; Preview stays the default). A PDF is recognised by
its `%PDF-` header, so one without the extension opens too. Continuous
scroll; ⌘+ / ⌘− zoom, ⌘0 actual size, ⌘9 fit to the window; View › Show
Page Thumbnails (⌥⌘B); ⌘F finds in the PDF with the find bar (⌘G / ⇧⌘G,
Match Case); select and ⌘C copies text; ⌘L is Go to Page; the status bar
shows page N of M and the zoom. A **floating control capsule** at the
bottom of the page (as in Preview) has previous / next page, an
editable "page N of M" field (Return jumps), zoom out / in, actual size,
fit width, fit page, thumbnails, find, rotate left / right (the view
only; the file is never changed) and Open in Default App. It fades after
about 2 seconds without a mouse move or scroll and comes back on the
next one (no fade with Reduce Motion), and stays while the pointer is
on it. ← / → and Page Up / Page Down turn the page. A link in a PDF
never opens in one click: a web or mail link asks first and shows the
whole address, a link to a file only shows it in Finder, and any other
kind of link is ignored. **File › Open as Text** puts the PDF's
text in a new untitled tab to edit (extracted in the background). Saving
and editing commands are off in a PDF tab, and Owlink never writes to a
PDF. A password-protected PDF asks for its password; a damaged one says
so. PDF tabs come back with the session on their page and zoom (a PDF
tab that isn't selected loads when you first click it); the owl stays
out of them.

### Images open in a viewer tab

**Images open in a viewer tab** (read-only): PNG, JPEG, GIF, HEIC/HEIF,
AVIF, WebP, TIFF, BMP, ICO, ICNS, JPEG 2000, PSD, TGA (whatever ImageIO
decodes), from every route a PDF takes (Open, drops, the Dock,
`cedric photo.jpg`, Open Recent, Reopen Closed Tab, the session).
Recognised by their first bytes, so one without its extension opens
too; SVG stays a text file with its preview. Fitted to the window (never
enlarged); ⌘+ / ⌘− zoom, ⌘0 actual size, ⌘9 fit, pinch to zoom, scroll
to pan; a checkerboard behind transparency; animated GIFs play (Pause /
Play button, or Space). The status bar shows pixel size, file size,
format, colour space and zoom. ⌘C copies the image; File › Open in
Preview (the file's default app); Print fits it to the page. A
right-click on the image has Zoom In, Zoom Out, Actual Size, Zoom to
Fit, Rotate Left / Right (the view only), Copy Image, Copy Path, Reveal
in Finder, Open in the default app and Show Info. A big
image is decoded downsampled (about 32 megapixels at most) off the main
thread, so a 12000×12000 PNG doesn't hold up typing in other tabs.
Owlink is an alternate image viewer (Preview stays the default) and
never writes to an image; image tabs come back with the session at
their zoom and place.

### Office and iWork documents open in a Quick Look tab

**Office and iWork documents open in a Quick Look tab** (read-only):
.docx .doc .xlsx .xls .pptx .ppt .pages .numbers .key .rtfd, shown by
Quick Look's own previewer. Told apart by their first bytes (a zip with
`[Content_Types].xml`, an OLE2 file) as well as the name. **File › Open
as Text** takes a Word document's text into a new untitled tab; for an
.xlsx the same item is **Open Sheet as CSV** (the first sheet, read
with Owlink's own zip and XML code: strings, numbers, booleans and
formulas' cached values; dates come out as their serial numbers). File ›
Open in <default app>. Registered as an alternate viewer.

### Certificates

A PEM file (`.pem` `.crt` `.cer` `.csr`, or any text
with a `-----BEGIN CERTIFICATE-----` block) opens in the editor with a
compact **Certificate** panel beside it. The text stays whole and
editable (⌘A ⌘C copies it exactly); the panel never replaces it, and
View › Preview › Show Preview (⌥⌘P) closes it, which is remembered for the next
certificate file until it is shown again. The panel lists each certificate in the file, in order, with an **Expired** /
**Expires in N days** badge and its subject, issuer, validity, other
names (SANs), whether it is a CA, key usage, what it is used for, public
key, signature algorithm, serial number and SHA-256 / SHA-1
fingerprints, in plain words, each with a **Copy** link, and **Copy
Certificate (PEM)** per certificate, which copies exactly that
certificate's BEGIN/END block from the text. It follows your edits. Private keys are
never read or shown ("Private key — not shown"; the owl's secret
warning still applies); a certificate request shows its subject; a
PKCS#7 bundle (`.p7b`, PEM or DER) lists its certificates. A binary
(DER) `.cer` `.crt` `.der` `.p7b` opens in a read-only certificate tab
with the same details; its main action is **Copy as PEM** (BEGIN/END
lines, 64 columns), and **Open as PEM Text** opens the PEM in a new
untitled tab. With the owl on, he
warns when a certificate in view has expired or expires within 30
days. Read with macOS's Security framework; nothing is sent anywhere.

## Git

For a file in a git repository (linked work trees
too) the status bar shows the branch, or the short commit when HEAD is
detached, with a dot when the file has uncommitted changes; clicking it
offers Copy Branch Name, Open Repository in Finder and Open on GitHub.
The gutter marks lines changed since the last commit as you type: green
for added, blue for modified, a small red triangle where lines were
deleted (Settings: "Show git changes in the gutter", on by default).
**File › Open on GitHub** and **Copy GitHub Link** link to the file
with `#L10` or `#L10-L20` for the selection (the branch if it has an
upstream, else the commit), for a github.com or GitHub Enterprise
`origin`; **File › Compare › Compare with Last Commit** shows the last commit
beside the current text. Owlink runs the local git only, after the
window is up, on a background queue; no network, no sign-in. Without
the developer tools (or another git) it does nothing, rather than
setting off the install prompt; very large documents are skipped.
A repository can't make Owlink run its programs: git is only
asked read-only questions (`rev-parse`, `cat-file`, `ls-files`, never
`status` or `diff`), with fsmonitor, hooks, pagers and diff drivers
forced off, and a repository whose own config names a program to run
(fsmonitor, filters, textconv, through `include`/`includeIf` too) gets
no git at all: the status bar says "Git info off". With "Show git
changes" off, git never runs.

## Cedric the owl

Everything Cedric does is in the **Cedric** menu (between Format and
Window): Ask Cedric… (⌥⌘/), Check Grammar with Cedric, Check Script for
Risks…, Show Cedric / Hide Cedric, Cedric’s Hints (Rules, or Rules + AI)
and Cedric AI Settings…. "Cedric" is always the assistant; "Owlink" is
the app.

### The owl and his hints

**Cedric the owl** (Cedric › Show Cedric, off by default): a small
assistant in the corner that offers one hint at a time, with **Fix it**
where a safe fix exists, **Show Me** where it points at something, **Not
now** and **Don't show again**. He blinks and glances now and then,
looks toward the caret when you stop typing (never moves while you
type), waves once per launch, points at the lines a hint is about, nods
when a fix is applied, thinks / searches / writes while the AI works,
and falls asleep after 5 minutes without typing (a click wakes him).
With Reduce Motion on (System Settings › Accessibility) he stays still:
no gestures, a single still frame for each state. His rules need no AI.
Most look at the text in view (at most 8 KB); some also check saved files
or wait until the whole file fits:
- warnings: merge-conflict markers left in the file; something that looks
  like a secret (a private key, an AWS key, a GitHub, Slack, Stripe or
  OpenAI/Anthropic token); JSON that doesn't parse (with the line; a
  trailing comma is named where it is: "Extra comma at the end of line
  5");
  an unmatched or unclosed bracket in Swift, JavaScript, TypeScript, C,
  CSS or Python (strings, comments and regexes skipped; "never closed"
  only in a saved file, and not in C with `#if`/`#else`); a file changed on disk under your edits;
- fixes: format one-line JSON; curly quotes pasted into code; tabs
  indenting YAML; tabs and spaces mixed (to whichever the file mostly
  uses; a Makefile keeps its tabs); zero-width and stray byte-order-mark
  characters; trailing spaces (never in a diff or patch, CSV, INI/.env
  or a log, where the spaces are data, nor in a certificate, key or other
  PEM text, nor inside a PowerShell here-string; in Markdown, two before another
  line of the paragraph are a line break and stay); "It looks like
  you're writing a to-do list" → Markdown checkboxes (one ⌘Z undoes the
  colouring too); a word typed twice ("the the", "the the the", also
  "por la la tarde"; **Show Me** selects it); two spaces
  after some full stops but not others; no newline at the end of a saved
  code file. Formatting JSON always does the whole file (checked
  first: if the whole file isn't valid JSON, nothing changes); in a
  file longer than his 8 KB view, the other fixes change only the part
  around what's on screen, and say so;
- offers and notes: plain text that is really Markdown, HTML or JSON
  (colour it that way); unsaved for two hours (save a copy); CRLF or
  mixed line endings; and, once ever, a letter (a greeting and a
  sign-off or address lines, not "Dear diary");
- typos: in prose only (writing that reads as sentences, never logs,
  config or `key=value` lines), "Fix 3 typos?" with **Fix Typos…** and
  **Fix All**, on his usual schedule: after a 3-second typing pause,
  when the rules have nothing, at most once every 10 minutes, and once
  after a prose file opens.

The bubble keeps off the lines it is about when the window has room.

Optional AI hints (Settings › Cedric, also Cedric › Cedric AI
Settings…; off by default) use a local model only. Each choice there
applies at once: ticking "Ask a local model for hints" or picking where
the AI runs or a model switches the engine without a Save. The network
address applies when you press Return or leave the field, and only once
it is a local one. Test Connection and each built-in model's Download,
Pause and Delete stay buttons, so nothing is downloaded or loaded until
you click. Automatic checks (and automatic AI grammar) are **off** by
default for LM Studio, Ollama and custom servers. The first time you
enable them, Cedric explains that visible text goes to the named server
on your local network, not the cloud. If they were already on for a
server, they stay off until that notice is confirmed. The existing Intel default remains
off for on-device engines so typing stays fast; click the owl and choose
**Ask AI Now**, or turn on "Check automatically when I pause typing" in
Settings › Cedric.
A one-word AI fix in prose ("definately" → "definitely") keeps its
**Fix it**.
In very large documents the owl only looks when clicked.
A network endpoint must resolve to a private address (loopback, LAN,
Tailscale); redirects to another host are refused.

### Cedric's checks

On top of the hints above, Cedric knows mistakes particular to some
languages: code that won't run, or runs and quietly does the wrong
thing. They never fire on text inside a string or a comment, run only
for their own language, and come one at a time like every other hint
(the most serious first). Where a fix is safe there is **Fix it**;
otherwise **Show Me** selects the place.

- **Shell scripts** (`.sh`, `.bash`, `.zsh`, a `#!` line):
  - Windows line endings: the script won't run ("bad interpreter").
    **Use LF** switches the file's line endings (one ⌘Z).
  - `NAME = value` where `$NAME` is used later: with spaces, the shell
    runs `NAME` as a command. Fix it removes them.
  - `if [$a = b ]` or `[ "$a" = "b"]`: `[` and `]` need spaces. Fix it
    adds them.
  - curly quotes and long dashes pasted from a web page or chat
    (`echo “hi”`, `ls –la`). Fix it straightens them.
  - a saved `.sh` file with no `#!` line that runs as a program (it reads
    its arguments, exits or runs commands at the top level; not a library
    of functions or settings another script sources, nor a file ShellCheck
    already manages). Fix it adds
    `#!/bin/sh`, or `#!/bin/bash` when the script uses bash features.
  - `cd somewhere` without `|| exit`, followed by an `rm`, `mv` or `cp`
    of a relative path: if the `cd` fails, they work on the wrong files.
    Fix it adds `|| exit 1`. (Not in a script with `set -e`.)
  - an unquoted `$var` in `rm`, `mv` or `cp`: a value with spaces or an
    empty one changes what gets deleted. Fix it adds quotes. (Not in
    zsh, which doesn't split variables.)
- **Python**:
  - `"\d"` and other backslashes that aren't escapes (a warning since
    Python 3.12). Fix it makes a raw string, or doubles the backslash
    when the string also has real escapes like `\n`. Docstrings are left
    alone.
  - a list, dict or set as a default argument (`def f(x=[])`): shared by
    every call. Show Me.
  - `x == None`: use `is None`. Fix it. (Not inside a call or a
    subscript, where SQLAlchemy and pandas mean it.)
  - `x is "a"`, `x is 0`: use `==`. Fix it.
  - Python 2 `print "hi"`. Fix it makes it `print("hi")`.
- **JavaScript and TypeScript**:
  - a `debugger` statement left in. Fix it removes it.
  - `x === NaN` (always false). Fix it uses `Number.isNaN(x)`.
  - `typeof x === "undefnied"`. Fix it picks the type name it was meant
    to be.
- **Configuration files**:
  - YAML: a key set twice in the same block (the second silently wins);
    a version such as `python-version: 3.10`, which YAML reads as the
    number 3.1 (Fix it quotes it).
  - JSON: a key set twice in the same object.
  - XML, `.plist` and `.svg` files that don't parse, with the line; a
    plist that is valid XML but not a valid property list. Only in a
    saved file.
  - TOML: a table or key defined twice; a bare word as a value (Fix it
    quotes it).
  - `.env`: spaces around `=` (Fix it removes them); a key set twice.
- **Markdown**:
  - a code block (```` ``` ```` or `~~~`) that is never closed, so the
    rest of the document shows as code. Show Me selects its opening line.
  - a link to `#a-heading` that no heading in the file makes (GitHub's
    anchors and the other common styles count, and so do `id=` and
    `{#id}` anchors). Fix it changes it to the nearest heading's anchor
    when one is close; otherwise Show Me.
  - a relative link or image whose file isn't there, relative to the
    document (`![logo](img/logo.png)`). Only in a saved document; the
    files are looked up in the background, so this hint can come a
    little after you open the file. Web links, `#anchors`, site-root
    paths, links to GitHub's own pages (`../../issues`) and generated
    `.html` aren't checked, nor the docs inside installed packages
    (`node_modules` and the like), nor a bare file name in an Obsidian
    vault or a Quartz site, which find files by name.
- **CSV and TSV**:
  - a field that opens with a quote and never closes: the rest of the
    file reads as one field. Show Me.
  - rows with more or fewer fields than the others (quoted separators
    and line breaks inside quotes are understood). Show Me selects the
    first such row.
- **SQL**:
  - `WHERE x = NULL` or `x <> NULL`: never true. Fix it uses `IS NULL` /
    `IS NOT NULL`. (`SET x = NULL`, defaults and `SET ANSI_NULLS OFF`
    scripts are left alone.)
  - `UPDATE` or `DELETE` with no `WHERE`: it changes or removes every
    row. Show Me.
- **PowerShell**:
  - `if ($a > 5)`: `>` writes `$a` to a file named `5`. Fix it uses `-gt`
    (or `-ge` for `>=`).
  - a space after the backtick at the end of a line: the line no longer
    continues. Fix it removes the space.

Generated scripts (`configure`, `config.status`, `libtool` and other
autoconf output) and minified code get none of these checks.

Some checks are about the whole file (a key set twice, a missing `#!`
line, XML that doesn't parse, `cd` before a delete): in a file longer
than Cedric's 8 KB view they wait until the whole file fits.

**Settings › Cedric › Style tips in code** (off by default) adds Cedric's style
suggestions: a bare `except:` in Python (Fix it: `except Exception:`),
`if x == True:` (Fix it: `if x:`, and `if not x:` for `== False`), shell
backticks (Fix it: `$(…)`), and a Markdown image without alt text (Fix
it starts one from the file name). The checks above are always on; each
hint still has its own **Don't show again**.

**Settings › Writing › Style Check** (off by default; like iA Writer's and
Ulysses') points out filler words ("very", "basically"), redundancies
("past history": Fix it makes it "history") and clichés ("at the end of
the day") in Markdown and plain-text prose, one phrase at a time. Code
blocks, code spans, links, URLs, tables and data files are never
checked. Each hint says why, and **Ignore this word** adds it to the
**Never flag** list; **Also flag** takes your own words or phrases (a
final `*` matches any ending: `utiliz*`). Offline, no AI. The list is
English for now; other languages can be added.

**Secrets.** When the text in view has something that looks like a key or
a token (AWS, GitHub, GitLab, Slack and Slack webhooks, Stripe, OpenAI or
Anthropic, Google API keys, npm tokens, a private key, or a password
inside a URL, `scheme://user:password@host`, when the password isn't a
placeholder), Cedric warns.
**Fix it** replaces it with a placeholder (`<REDACTED>`, `<password>`, or
for a private key the whole block) in one ⌘Z.

**Downloaded scripts.** When you open a script that came from the
internet (a shell, PowerShell, batch, Python or Ruby file with macOS's
quarantine attribute), Cedric offers **Check Script for Risks…** once for
that file.

**.editorconfig.** For a saved file under a folder with an
`.editorconfig`, Cedric follows it: `trim_trailing_whitespace = false`
and `insert_final_newline = false` turn those hints off
(`insert_final_newline = true` asks for the final newline in any file),
`indent_style` decides which way mixed indentation is converted (at
`indent_size`), and a file indented entirely the other way gets "Convert?"
(not Makefiles or Go). The file is read in the background the first time
Cedric looks at the document.

### Explain Regex, Decode Selection, Find TODOs

In Text › Text Tools, and in the owl's menu when they apply. All three
work offline.

- **Explain Regex** (with a regular expression selected; a JavaScript
  `/…/flags` literal works too): a breakdown, one line per piece, nested
  under its group: anchors, classes, sets, groups (named, non-capturing,
  lookahead and lookbehind), alternation, quantifiers (lazy, possessive),
  back-references and flags. It warns about patterns that can take
  exponential time, like `(a+)+`, and says what it doesn't know rather
  than guessing.
- **Decode Selection**: a JWT shows its header and payload as JSON and
  when it expires (its signature is not checked, and it isn't sent
  anywhere); base64 (standard or URL-safe) that is text shows the text;
  a Unix time (10 digits, or 13 for milliseconds) shows the date, in your
  time zone and in UTC. **Copy** copies the result.
- **Find TODOs** lists the TODO, FIXME, HACK and XXX notes in the file
  (in code, only in comments) with their line numbers; click one to go
  there.

### Ask Cedric

**Explain Selection** (⌥⌘E) and **Rewrite Selection** (⌥⇧⌘E) are
available in the Cedric menu, the editor's context menu, and the Markdown
Context Bar. Select text first and turn on Ask Cedric with a local engine
ready. Explain works with any ready engine; Rewrite requires a model that
passes the existing tool gate (at least 80%, with unmeasured models off).
For a server set to choose its model automatically, Rewrite becomes
available after Ask Cedric has resolved that model and its score.
Rewrite offers the existing Apply / Skip cards; nothing changes until
you apply a proposal. Engines run on this Mac or a configured private
LAN server, never in the cloud.

**Ask Cedric** (Settings › Cedric › "Ask Cedric"; on by default when a local
engine is ready: Apple Intelligence, a downloaded built-in model, or an
LM Studio / Ollama / other-Mac server you set up and turned on; with
none, clicking the owl offers **Set Up Ask Cedric…**). Click the owl:
**Ask about this file…** is the first item; Cedric › Ask Cedric… (⌥⌘/)
does the same, and the owl says so once, a while after a new user's
first launch. A small panel about the current document opens (a
floating panel you can drag anywhere; it hides when you switch tabs and
comes back with its tab). A chip
picks what Cedric sees (Selection, Visible text, or the Whole document
when it fits the model); quick actions **Explain** (**What Does It
Do?** for scripts), **Explain Line** (the selection or the caret's
line), **Find Problems**, **Summarise** / **Rewrite** (prose),
**Simplify** and **Add Comments** (code), or type a question. Answers
stream in (built-in, Apple Intelligence, or LM Studio / Ollama on this
Mac or the local network, never the cloud; a slow model gets 2 minutes
for its first word, then 30 s between words, up to 15 minutes in all);
**Stop** cancels. An edit is never
made by the model: each change it proposes (up to five per answer)
comes back as a card with its reason, the before and after, and
**Apply** / **Skip**. Apply is one undo step, and works only while the
text it replaces is in the document exactly once: typing elsewhere is
fine, but if that text changed or now appears twice, the card says
"Text changed or isn't unique; ask again" (with **Ask Again**). A
read-only document never applies. (A Rewrite or Add Comments answer from
a model without tools comes back as one card for the lines it was shown,
applicable only while the document is unchanged since you asked.)
History is per document, in memory only, with **Copy as Markdown** and
**Clear**.
Cedric can also use read-only tools on a frozen copy of the
document (get the selection or lines, search, outline, counts, the
offline checks' findings with check_document, one Markdown section by
its heading with read_section, and propose_edit, which names the exact
text to change and its replacement, offered only when the question asks
for a change: "rewrite", "fix", "shorten", "rephrase", "correct"…, not
"is this correct?"), plus describe_image
for an SVG's picture (below), at most three rounds per question. A
question is offered only the few tools it needs (get_lines, search and
outline, and the others when the question or the document calls for
them). Tools go only to
models that score at least 80% on a fixed 58-prompt set
(`Scripts/owl-tools-eval.sh`, scores in
`Resources/AI/owl-tool-scores.json`). Other models get the quick
actions without tools. Measured 2026-11-21 on the 58-prompt set (eight
of them on proposing edits, or not), with each prompt offered only its
own few tools: the built-in Qwen3 4B Instruct 87.9%, so it gets tools.
Measured 2026-11-20 on the 50-prompt set: Apple Intelligence 52% stays without
(it scores differently from run to run; it was 72.5% on the older
40-prompt set). Measured 2026-11-18/19 on the 40-prompt set and not
re-run since: Qwen2.5-Coder 1.5B on LM Studio 75% and the built-in
Qwen2.5-Coder 3B 65%, both without. A model without tools asked about problems ("what problems
does this file have?") gets the offline checks' list in its prompt
instead.

**Pictures.** Asked about an SVG ("What is it a picture of?"), Cedric
can look at the picture the preview shows: the **describe_image** tool
renders the file as it is in the editor (unsaved changes included) with
the preview's own renderer, page scripts and network off, then Apple's
Vision framework reads it on this Mac: what it looks like (with how
sure it is), any text in it, faces, its size and main colours. Vision's
labels are a photo classifier's guesses and are often wrong for icons
and line art; Cedric is told so and weighs them against the file's
code. On macOS 27 with Apple Intelligence, the model also gets the
rendered picture itself and can say what it shows. describe_image is
read-only, looks only at the open document, sends nothing anywhere
(the picture never leaves your Mac, even when the chat uses an LM
Studio / Ollama server: only its short text description goes to the
model, like the rest of the chat), and is offered only for SVG files,
even to models that get no other tools. Nothing loads until it is
used; the picture is drawn at most 512 pixels across (larger ones are
scaled down) and the look is given up after 20 seconds. Image and PDF
tabs don't have Ask Cedric.

The owl in the editor follows the conversation (the panel has no owl
of its own): he waves when the panel opens, glances toward it while you
type, thinks while the model works (with a magnifier while he searches
the document), talks while the answer streams in, writes while he
proposes an edit, nods when it's done and flaps his wings when you
Apply it. After an error, or with no AI engine set up, he looks sleepy.
While he is busy with the chat, his own blinks and hints wait; they
come back when the chat is idle or closed. With Reduce Motion on
(System Settings › Accessibility › Display) he only changes between
still poses.

The panel opens beside the owl, wherever you have put him, on the side
of the screen with more room. Drag it anywhere: once you have moved it,
it opens where you left it until you quit Owlink. With Cedric hidden
(**Hide Cedric**), Ask Cedric works the same and the panel opens at the
window's bottom-right corner; opening it doesn't bring him back.

### Check Script for Risks…

**Check Script for Risks…** (Cedric menu, the owl, or **Check for
Risks** in Ask Cedric) for shell, PowerShell, batch, `.reg`, Python and
Ruby: an offline scan, no AI and nothing sent anywhere (so it works on
any Mac, Intel included), lists the lines worth reading first:
downloading and running code (`curl … | sh`, `| /bin/bash`, through
`tee`, `iex (iwr …)`, Python `exec` / Ruby `eval` of fetched code),
`Invoke-Expression` / `eval` and AppleScript `do shell script`, encoded
commands (`-EncodedCommand`, Base64 piped to a shell or `exec`'d,
`&(gcm i*x)`), reverse shells (`/dev/tcp`, `nc -e`), setuid
(`chmod u+s`), registry and system changes, `sudo` and `-Verb RunAs`,
reading passwords or keys, turning off Defender / Gatekeeper / the
firewall / the execution policy / quarantine / TCC, running at login
(launch agents, cron, Run keys, scheduled tasks, `authorized_keys`),
and recursive deletes of broad paths (`rm -rf ~/*`, `rm -rf "$DIR/"*`,
`find / … -delete`, `Remove-Item -Recurse C:\`). Only the first 20,000
lines are scanned, and a longer script says so. With Ask Cedric on, the
model then reviews the script with those findings (passed as data, and
told the script's text is never instructions) and ends with a verdict:
"No obvious red flags (not a guarantee)", "Run only if you trust the
source" or "Don't run it". Cedric never calls a script safe: the app
rewrites any such line (also while the answer streams in), and forces "Don't run it — review the flagged
lines" after a high-risk finding or when only part of the script was
reviewed, whatever the model said.

## Help menu

**Owlink Help** (⌘?, this manual, as of the version you have: a
release opens the manual at its own tag on GitHub), **Keyboard
Shortcuts** (every menu shortcut in one window), **Owlink on GitHub**,
**Report an Issue…** and the system's menu search. Owlink › About
Owlink shows the version, the author, the licence (BSD-2-Clause) and
the credits: llama.cpp (MIT) for the built-in AI, and each AI model,
downloaded only on request, under its own licence.

## The cedric command

A **`cedric` command-line launcher**, with `-w` so it can be
git's editor, and `file:line:col`.
`Owlink.app/Contents/Resources/cedric` opens files in the running app (or
starts it). The command keeps the name `cedric`. Link it onto your PATH:

```sh
ln -s "/Applications/Owlink.app/Contents/Resources/cedric" /usr/local/bin/cedric
cedric notes.md                 # open (a missing file opens as a new tab that saves there)
cedric src/main.c:120           # open at line 120 (also: cedric +120 src/main.c)
cedric src/main.c:120:7         # line 120, column 7 (grep -n / compiler output works too)
git log | cedric -              # stdin into a new untitled tab
git config --global core.editor "cedric -w"   # -w / --wait: return when the tab closes
cedric ~/src/project            # a folder opens in the folder sidebar (-w returns at once: no tab to wait for)
```

It talks to the app through a `cedric://open?path=…&line=…&col=…` URL. Any
app or web page can send such a URL, so each one the script sends proves it
comes from you with a secret token (`~/Library/Application Support/Cedric/cli-token`,
readable only by you; the `Cedric` folder itself is owner-only, 0700, and the
token is written to a temp file and moved into place, so it is never read
half-written). Owlink makes a new token every time it starts. The token is
never on a command line, where other users of the Mac could see it: the
script writes it to a `cedric-auth.*` file in your temp folder (readable
only by you), passes that file's name, and Owlink reads it once and deletes
it. A link without it can't hand over stdin or `-w` files, and opening a
file from it asks first, showing the full path (hidden or direction-changing
characters are shown as `<U+202E>`-style codes). The app deletes only the
script's own temp files (`cedric-stdin.*`, `cedric-wait.*`, `cedric-auth.*`
in your temp folder), checked after `..` and symlinks are resolved.
With `-w` the script makes a `cedric-wait.*` marker file in the temp
folder and passes it along; Owlink deletes it when that file's tab closes
(or when Owlink quits), and the script returns.

## Privacy and what stays on this Mac

The AI engines run on this Mac or a server on your own network, never
the cloud. What Owlink keeps on this Mac, all under
`~/Library/Application Support/Cedric/` (owner-only, 0700; files 0600):

- **`Session/`**: the open tabs and the **unsaved text** of open and
  closed tabs, in plain text, so tabs come back after a quit or a crash.
  Anything you type or paste into a tab, a password included, is written
  here until you save or close it and it expires. A closed tab's text is
  kept for 30 days after closing (at most 100 such tabs), then deleted.
  This folder is **excluded from Time Machine**: it is working state for
  this Mac, so backups don't keep copies of unsaved text.
- **`ReplaceUndo/`**: the original of every file Replace in Files
  changed, for Undo Replace in Files: the last 5 replaces, at most 7
  days. Also excluded from Time Machine (the files themselves are backed
  up as usual).
- **`Models/`**: downloaded AI models (excluded from Time Machine; they can
  be downloaded again). A model's checksum is checked again before it is
  first loaded and whenever the file changes; a model that doesn't match
  isn't loaded.
- **`cli-token`**: the `cedric` command's secret, new at every launch.

An AI server on your network (LM Studio, Ollama) must be named or
addressed privately: loopback, a LAN address, Tailscale, or an IPv6
link-local address with its interface, such as `http://[fe80::1%en0]:1234`.
Before each request Owlink looks the name up and refuses it unless every
address is private. Over plain **http** the request then goes to that
checked address, so a DNS answer that changes a moment later can't send
your text elsewhere. Over **https** it can't (the server's certificate is
chosen and checked by name), so the certificate must match the name, and
after each request Owlink checks the address it actually connected to:
if it was public, the answer is thrown away and you see an error, but
that one request had already been sent. If you worry about your local
DNS, use plain http on your LAN, or the server's address instead of its
name.

A release build of Owlink ignores the `CEDRIC_*` developer and test
switches (they could make it open files or load a model at another
program's request); only the few that open nothing, such as the launch
check's, are left.

## Building from source

Needs the Command Line Tools or Xcode 26 (Swift 6.3 or later, macOS 26 SDK); Xcode itself is not required. Swift 6.1 / 6.2 with an older SDK still compiles and passes the unit tests, but the app it builds draws no editor text, so never ship or test the app from an older toolchain. Releases are built on GitHub's macos-26 runner.

```sh
Scripts/bundle-app.sh               # "dist/Owlink.app" for this Mac, ad-hoc signed, a CHECK build
Scripts/bundle-app.sh --universal   # arm64 + x86_64
Scripts/bundle-app.sh --release     # as shipped: without the CEDRIC_* test switches
open "dist/Owlink.app"
```

Tests (Swift Testing; the script adds the paths the Command Line Tools need):

```sh
Scripts/test.sh                     # unit tests: tokenizers, Markdown, codecs, find, session store, themes
Scripts/session-check.sh            # end to end: unsaved tabs survive a kill -9, a normal quit and a last-window close
Scripts/typing-check.sh             # real key events in every theme; typed glyphs' pixels must be visible
Scripts/launch-check.sh             # real launches: stays up, quits cleanly, no crash report
Scripts/launch-check.sh --release   # the same for a build to ship: fails unless it reports "dev hooks: off"
Scripts/pdf-check.sh                # PDF tabs in the running app: find, copy, zoom, Open as Text, session
Scripts/image-check.sh              # image and Office tabs: zoom, copy, GIFs, docx/xlsx text, session, a 12000² PNG vs typing
Scripts/launch-speed-check.sh       # launch phase medians: empty, 8-tab session, 500 KB file
swift Scripts/launch-time.swift "dist/Owlink.app" /System/Applications/TextEdit.app
```

`bundle-app.sh` makes a check build by default: the check scripts drive it
with `CEDRIC_*` switches (open files, take snapshots), so don't use it as
your everyday copy. `Scripts/release.sh` builds with `--release`.
A local build is ad-hoc signed, not notarized. If macOS refuses to open a
copied build, remove the quarantine flag: `xattr -dr com.apple.quarantine "Owlink.app"`.

## Releases

Signed with Developer ID and notarized, from `Scripts/release.sh` (locally or
by the Release workflow on a `v*` tag); see `CHANGELOG.md` for what each
version has, including its known gaps, and *Signing a release* in
`docs/architecture.md` for the pipeline.

## Design notes

- **Own tab model, not NSDocument.** Notepad++'s model (quit without prompts,
  restore everything) fights NSDocument's unsaved-changes review on quit and
  its own autosave locations for untitled documents. `EditorDocument` is a
  small model; `SessionStore` (in CedricCore, tested) writes `session.json`
  and one buffer file per unsaved tab, atomically, buffers first.
- **Hand-written highlighter, not tree-sitter.** Each language is a line
  tokenizer: a pure function of (line, state at line start) → tokens + state
  at line end, scanning UTF-16 directly. The engine caches the state at each
  line start, so an edit only invalidates from the edited line down, and
  colouring the viewport only scans from the last known state. Languages
  without cross-line state (JSON, YAML, plain) never scan above the viewport.
  Colours are applied as foreground-colour attributes on the visible lines
  (not registered with undo); new text starts in the theme's text colour.
  Tree-sitter would parse more
  correctly (real grammars, nesting, embedded languages) but brings a C
  runtime plus one generated parser per language (several MB of C each),
  parses whole files up front, and would be the project's first external
  dependency; see `docs/architecture.md`. The `Tokenizer` protocol leaves room
  to plug one in later for specific languages.
- **Own Markdown renderer, not swift-markdown.** `Markdown.render` covers
  what notes and READMEs use (headings, emphasis, code spans and fences,
  lists with nesting and task items, block quotes, tables, links, images,
  autolinks, raw HTML blocks) in about 500 lines with no dependencies.
  swift-markdown would mean swift-markdown plus swift-cmark (C). Known
  differences from CommonMark: no reference-style links, simplified emphasis
  rules and lazy continuation. `data-line` attributes drive scroll sync.

More in [docs/architecture.md](architecture.md).

## Not built yet

Macros and automatic updates; folding HTML and XML tags; per-pane folds in split view. See
`docs/architecture.md` for where they plug in.

## Built with Claude

Owlink is built with Claude: Claude Code agents under d4rkwyng's direction, with
review and tests before release.

## Licences

BSD-2-Clause. See [LICENSE](../LICENSE). The Dracula theme's colours are by
[Dracula Theme](https://draculatheme.com), used under the MIT license.

The built-in AI engine uses [llama.cpp](https://github.com/ggml-org/llama.cpp)
(MIT, © the ggml authors), bundled as `llama.framework`. Models are not
bundled: the ones Owlink offers to download are Qwen models by Alibaba
Cloud, each under its own licence. Download first opens a confirmation
with the model name, licence name and full bundled licence text; no
network fetch is made just to show it. Non-commercial terms are flagged
clearly. The default, Qwen3 4B Instruct (2507, the Q4_K_M GGUF quantised
by Unsloth), is Apache-2.0, as are Qwen2.5-Coder 1.5B and 7B and Qwen3
4B. Qwen2.5-Coder 3B, the default before, stays an optional download
labelled "Non-commercial licence" (Qwen Research License).
