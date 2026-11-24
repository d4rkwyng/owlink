#!/usr/bin/env python3
"""ios-gate-axe.py: the gate's touch driver (AXe), on one gate simulator.

Not a replacement for the XCUITests (they are the gate's pass/fail source of
truth); a second, independent path through the real app with real HID
events from AXe:

  open a document -> the ••• menu (and its Preview submenu) -> Ask Cedric ->
  Done -> ⌘, (axe key-combo --modifiers 227 --key 54) -> Settings' Done ->
  the back chevron.

After each step it saves `axe describe-ui` JSON and an `axe screenshot`
under <out>/<device>-<n>-<step>.{json,png} and checks, from the JSON:
  - the open ••• menu's main list has no label twice, and Focus Preview at
    most once; its Preview submenu has Focus Preview at most once;
  - Ask Cedric opens (its Done) and goes with Done;
  - ⌘, shows Owlink's Settings (settings.font), with Owlink still in front;
  - the back chevron closes the document (the file list's browser.settings,
    no editor.text).

Usage: ios-gate-axe.py <udid> <device-name> <app-path> <out-dir>
Prints one "AXE <device> PASS|FAIL ..." line last; exit 0 on PASS, 1 on FAIL.
Every axe call has --udid; DEVELOPER_DIR is set by the caller.
"""
import json
import os
import subprocess
import sys
import time

BUNDLE = "app.owlink.ios"
AXE = os.environ.get("AXE", "axe")


class Driver:
    def __init__(self, udid, device, app, out):
        self.udid, self.device, self.app, self.out = udid, device, app, out
        self.step = 0
        self.failures = []
        self.notes = []
        os.makedirs(out, exist_ok=True)

    # -- axe and simctl ---------------------------------------------------
    def axe(self, *args, check=True):
        cmd = [AXE, *args, "--udid", self.udid]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if check and r.returncode != 0:
            raise RuntimeError(f"{' '.join(cmd)}: {r.stderr.strip() or r.stdout.strip()}")
        return r

    def tree(self):
        r = self.axe("describe-ui", "--minimal-keys", check=False)
        try:
            return json.loads(r.stdout)
        except ValueError:
            return []

    def save(self, name):
        """describe-ui JSON and a screenshot for this step; returns the tree."""
        self.step += 1
        base = os.path.join(self.out, f"{self.device}-{self.step}-{name}")
        tree = self.tree()
        with open(base + ".json", "w") as f:
            json.dump(tree, f, indent=1)
        self.axe("screenshot", "--output", base + ".png", check=False)
        return tree

    def fail(self, msg):
        self.failures.append(msg)
        print(f"  {self.device}: FAIL {msg}")

    def ok(self, msg):
        print(f"  {self.device}: ok   {msg}")

    # -- the tree ---------------------------------------------------------
    @staticmethod
    def walk(node, clip=None, path=()):
        """(element, visible rect, ancestors) for every element: the
        visible rect is the element's frame clipped by its ancestors'."""
        if isinstance(node, list):
            for n in node:
                yield from Driver.walk(n, clip, path)
            return
        f = node.get("frame") or {}
        rect = (f.get("x", 0), f.get("y", 0), f.get("x", 0) + f.get("width", 0), f.get("y", 0) + f.get("height", 0))
        vis = rect if clip is None else (max(rect[0], clip[0]), max(rect[1], clip[1]), min(rect[2], clip[2]), min(rect[3], clip[3]))
        yield node, vis, path
        # Zero-size containers don't clip (accessibility often reports them so).
        child_clip = vis if (rect[2] > rect[0] and rect[3] > rect[1]) else clip
        for c in node.get("children") or []:
            yield from Driver.walk(c, child_clip, path + (node,))

    def find(self, tree, ident=None, label=None, kind=None):
        out = []
        for e, vis, path in self.walk(tree):
            if ident is not None and e.get("AXUniqueId") != ident:
                continue
            if label is not None and e.get("AXLabel") != label:
                continue
            if kind is not None and e.get("type") != kind:
                continue
            out.append((e, vis, path))
        return out

    @staticmethod
    def visible(vis, min_h=8):
        return vis[2] - vis[0] > 4 and vis[3] - vis[1] > min_h

    def wait_for(self, ident=None, label=None, gone=False, timeout=12):
        end = time.time() + timeout
        while True:
            tree = self.tree()
            hits = [h for h in self.find(tree, ident, label) if self.visible(h[1], 2)]
            if bool(hits) != gone:
                return True
            if time.time() > end:
                return False
            time.sleep(0.5)

    def tap_vis(self, vis):
        x, y = (vis[0] + vis[2]) / 2, (vis[1] + vis[3]) / 2
        self.axe("tap", "-x", f"{x:.0f}", "-y", f"{y:.0f}")

    # -- the menu ---------------------------------------------------------
    def menu_container(self, tree):
        """The open menu: the deepest container of its rows, the largest set
        (4 or more) of labelled buttons sharing one x and width, which bar
        buttons don't. (Rows scrolled far out of view drop out of the tree,
        so no single row is a reliable anchor.)"""
        groups = {}
        for e, vis, path in self.walk(tree):
            if e.get("type") == "Button" and e.get("AXLabel"):
                f = e.get("frame") or {}
                key = (round(f.get("x", 0)), round(f.get("width", 0)))
                if key[1] >= 120:
                    groups.setdefault(key, []).append((e, path))
        rows = max(groups.values(), key=len, default=[])
        if len(rows) < 4:
            return None, None
        ids = {id(e) for e, _ in rows}
        for anc in reversed(rows[0][1]):
            if ids <= {id(n) for n, _, _ in self.walk(anc)}:
                return anc, next(v for n, v, _ in self.walk(tree) if n is anc)
        return None, None

    def menu_buttons(self, tree):
        """The menu's labelled buttons, each with its visible rect clipped
        by every ancestor (walked from the root, not from the menu)."""
        menu, _ = self.menu_container(tree)
        if menu is None:
            return []
        return [(e, v) for e, v, path in self.walk(tree)
                if e.get("type") == "Button" and e.get("AXLabel") and any(p is menu for p in path)]

    def open_menu(self):
        more = self.find(self.tree(), ident="TopOverflowBarButtonItem") or self.find(self.tree(), label="More", kind="Button")
        if not more:
            raise RuntimeError("no ••• (More) button")
        self.tap_vis(more[0][1])
        end = time.time() + 6
        while time.time() < end:
            if self.menu_buttons(self.tree()):
                return True
            time.sleep(0.4)
        return False

    def menu_open(self, tree):
        """Any menu row on screen (a submenu has too few rows for
        menu_container), or the ••• button gone behind the menu."""
        rows = [h for h in self.find(tree, kind="Button")
                if str(h[0].get("AXUniqueId") or "").startswith("editor.menu.") and self.visible(h[1], 2)]
        more = [h for h in self.find(tree, ident="TopOverflowBarButtonItem") if self.visible(h[1], 2)]
        return bool(rows) or bool(self.menu_buttons(tree)) or not more

    def close_menu(self):
        """Escape, then a tap outside the menu (on the status line), until
        the menu is gone and the ••• button is back."""
        for attempt in range(4):
            tree = self.tree()
            if not self.menu_open(tree):
                return True
            if attempt % 2 == 0:
                self.axe("key", "41", check=False)  # Escape
            else:
                app = tree[0]["frame"] if tree else {"width": 400, "height": 800}
                self.axe("tap", "-x", f"{app['width'] / 2:.0f}", "-y", f"{app['height'] * 0.98:.0f}", check=False)
            time.sleep(1.2)
        return not self.menu_open(self.tree())

    def tap_menu_item(self, label):
        """Scrolls the open menu until the item is inside the menu's visible
        area (the tree lists items below its bottom too), then taps it."""
        for attempt in range(12):
            tree = self.tree()
            menu, mvis = self.menu_container(tree)
            if menu is None:
                return False
            for e, vis in self.menu_buttons(tree):
                if e.get("AXLabel") == label and self.visible(vis, 20):
                    self.tap_vis(vis)
                    return True
            # Swipe inside the menu: up for the first half, then back down.
            cx = (mvis[0] + mvis[2]) / 2
            top, bottom = mvis[1] + 60, mvis[3] - 60
            if bottom - top < 60:
                return False
            # Half the menu's visible height per swipe (a longer swipe flings
            # past the item).
            mid, half = (top + bottom) / 2, (bottom - top) / 4
            a, b = (mid + half, mid - half) if attempt < 6 else (mid - half, mid + half)
            self.axe("swipe", "--start-x", f"{cx:.0f}", "--start-y", f"{a:.0f}", "--end-x", f"{cx:.0f}",
                     "--end-y", f"{b:.0f}", "--duration", "0.6", check=False)
            time.sleep(1)
        return False

    # -- the run ----------------------------------------------------------
    def run(self):
        sim = ["xcrun", "simctl"]
        subprocess.run(sim + ["install", self.udid, self.app], check=True, capture_output=True)
        subprocess.run(sim + ["launch", "--terminate-running-process", self.udid, BUNDLE,
                              "-OwlinkOpen", "README.md", "-OwlinkResetSettings", "-OwlinkFreshSample"],
                       check=True, capture_output=True)

        # 1. The document is open.
        if not self.wait_for(ident="editor.text", timeout=25):
            self.save("editor")
            self.fail("the document didn't open (no editor.text)")
            return
        time.sleep(2)
        self.save("editor")
        self.ok("document open")

        # 2. The ••• menu: no label twice, Focus Preview at most once.
        if not self.open_menu():
            self.save("menu")
            self.fail("the ••• menu didn't open")
            return
        time.sleep(1)
        tree = self.save("menu")
        labels = [e["AXLabel"] for e, _ in self.menu_buttons(tree)]
        dupes = sorted({l for l in labels if labels.count(l) > 1})
        focus = labels.count("Focus Preview")
        if dupes:
            self.fail(f"••• menu lists twice: {dupes}")
        if focus > 1:
            self.fail(f"••• menu lists Focus Preview {focus} times")
        if not dupes and focus <= 1:
            self.ok(f"••• menu: {len(labels)} items, none twice, Focus Preview {focus}x in the main list")

        # 3. Its Preview submenu: Focus Preview at most once.
        if self.tap_menu_item("Preview"):
            time.sleep(1.5)
            tree = self.save("menu-preview")
            # Every Focus Preview on screen but the bar's own ↖↘ button
            # (editor.focusPreview), which isn't a menu item.
            n_menu = sum(1 for e, vis, _ in self.find(tree, label="Focus Preview", kind="Button")
                         if e.get("AXUniqueId") != "editor.focusPreview" and self.visible(vis, 2))
            if n_menu > 1:
                self.fail(f"the Preview submenu lists Focus Preview {n_menu} times")
            else:
                self.ok(f"Preview submenu: Focus Preview {n_menu}x")
        else:
            self.fail("no Preview item in the ••• menu")
        if not self.close_menu():
            self.save("menu-close")
            self.fail("the ••• menu didn't close (Escape, then a tap outside)")
            return

        # 4. Ask Cedric, then Done.
        if not self.open_menu() or not self.tap_menu_item("Ask Cedric"):
            self.save("ask-cedric")
            self.fail("couldn't reach Ask Cedric in the ••• menu")
            return
        if not self.wait_for(ident="ask.done", timeout=12):
            self.save("ask-cedric")
            self.fail("Ask Cedric didn't open (no ask.done)")
            return
        time.sleep(1)
        self.save("ask-cedric")
        self.ok("Ask Cedric open")
        done = [h for h in self.find(self.tree(), ident="ask.done") if self.visible(h[1], 2)]
        self.tap_vis(done[0][1])
        if not self.wait_for(ident="ask.done", gone=True, timeout=8):
            self.save("ask-cedric-done")
            self.fail("Ask Cedric didn't close with Done")
            return
        time.sleep(1)
        self.save("ask-cedric-closed")
        self.ok("Ask Cedric closed with Done")

        # 5. ⌘, (Left Command + comma): Owlink's Settings, Owlink in front.
        self.axe("key-combo", "--modifiers", "227", "--key", "54")
        shown = self.wait_for(ident="settings.font", timeout=8)
        tree = self.save("settings-command-comma")
        if not shown:
            self.fail("⌘, didn't show Owlink's Settings (no settings.font)")
            return
        if not self.find(tree, ident="editor.text") and not self.find(tree, label="Owlink"):
            self.fail("⌘, left Owlink")
            return
        self.ok("⌘, opened Owlink's Settings")
        done = [h for h in self.find(tree, label="Done", kind="Button") if self.visible(h[1], 2)]
        if not done:
            self.fail("no Done in Settings")
            return
        self.tap_vis(done[0][1])
        if not self.wait_for(ident="settings.font", gone=True, timeout=8):
            self.fail("Settings didn't close with Done")
            return
        time.sleep(1)

        # 6. The back chevron closes the document.
        back = [h for h in self.find(self.tree(), ident="BackButton") if self.visible(h[1], 2)]
        if not back:
            self.save("back")
            self.fail("no back chevron")
            return
        self.tap_vis(back[0][1])
        closed = self.wait_for(ident="editor.text", gone=True, timeout=12)
        # The file list is the system document browser: its own tree
        # usually doesn't reach AXe (only the Application node does), so
        # "closed" is: no editor text, no back chevron, no README.md title.
        listed = self.wait_for(ident="browser.settings", timeout=4)
        time.sleep(1)
        tree = self.save("back-file-list")
        left = [what for what, hits in (("editor.text", self.find(tree, ident="editor.text")),
                                        ("BackButton", self.find(tree, ident="BackButton")),
                                        ("README.md", self.find(tree, ident="README.md")))
                if any(self.visible(h[1], 2) for h in hits)]
        if not closed or left:
            self.fail(f"the back chevron didn't close the document (still on screen: {left or ['editor.text']})")
            return
        self.notes.append("file list " + ("seen (browser.settings)" if listed else "not in AXe's tree (system browser)"))
        self.ok("back chevron closed the document")


def main():
    udid, device, app, out = sys.argv[1:5]
    d = Driver(udid, device, app, out)
    try:
        d.run()
    except Exception as e:  # a driver error is a failure, never a pass
        d.fail(f"driver error: {e}")
    steps = d.step
    if d.failures:
        print(f"AXE {device} FAIL ({len(d.failures)}): {'; '.join(d.failures)} [{steps} steps saved]")
        sys.exit(1)
    notes = f" ({'; '.join(d.notes)})" if d.notes else ""
    print(f"AXE {device} PASS{notes}: document, ••• menu (+ Preview submenu), Ask Cedric open/Done, ⌘, Settings, back chevron [{steps} steps saved]")


if __name__ == "__main__":
    main()
