import CoreGraphics
import Foundation
import Testing
@testable import CedricCore

/// The iOS editor's panes (EditorPanes): never three columns, Ask Cedric
/// as the side panel on wide screens taking the preview's place, and the
/// owl kept off the chat.
@Suite struct EditorPanesTests {
    @Test func askPanelReplacesThePreviewOnAWideScreen() {
        let l = EditorPanes.layout(previewOn: true, askOpen: true, focus: false, regularWidth: true)
        #expect(l == EditorPanes.Layout(text: true, preview: false, ask: .panel))
        #expect(l.columns == 2)
        // Closed again: the preview is back.
        let back = EditorPanes.layout(previewOn: true, askOpen: false, focus: false, regularWidth: true)
        #expect(back == EditorPanes.Layout(text: true, preview: true, ask: .none))
    }

    @Test func neverThreeColumns() {
        for p in [false, true] { for a in [false, true] { for f in [false, true] { for r in [false, true] {
            let l = EditorPanes.layout(previewOn: p, askOpen: a, focus: f, regularWidth: r)
            #expect(l.columns <= (r ? 2 : 1))
            #expect(l.columns >= 1)
        } } } }
    }

    @Test func compactShowsOnePaneAndTheSheet() {
        #expect(EditorPanes.layout(previewOn: true, askOpen: true, focus: false, regularWidth: false)
                == EditorPanes.Layout(text: false, preview: true, ask: .sheet))
        #expect(EditorPanes.layout(previewOn: false, askOpen: true, focus: false, regularWidth: false)
                == EditorPanes.Layout(text: true, preview: false, ask: .sheet))
    }

    @Test func focusPreviewIsThePreviewAlone() {
        for r in [false, true] {
            let l = EditorPanes.layout(previewOn: true, askOpen: false, focus: true, regularWidth: r)
            #expect(l == EditorPanes.Layout(text: false, preview: true, ask: .none, focus: true))
        }
        // Ask Cedric opening ends it.
        #expect(!EditorPanes.layout(previewOn: true, askOpen: true, focus: true, regularWidth: true).focus)
    }

    @Test func wideScreenAlwaysGetsThePanel() {
        #expect(EditorPanes.askPresentation(regularWidth: true) == .panel)
        #expect(EditorPanes.askPresentation(regularWidth: false) == .sheet)
        // A sheet left up from the folded phone becomes the panel when it opens, and back.
        #expect(EditorPanes.askSwitch(from: .sheet, regularWidth: true) == .panel)
        #expect(EditorPanes.askSwitch(from: .panel, regularWidth: false) == .sheet)
        #expect(EditorPanes.askSwitch(from: .panel, regularWidth: true) == nil)
        #expect(EditorPanes.askSwitch(from: .none, regularWidth: true) == nil)
    }

    @Test func owlAreaStopsAtTheChatPanel() {
        // A stale text pane still running under the panel (the screenshot's case).
        let text = CGRect(x: 0, y: 0, width: 1300, height: 800)
        let chat = CGRect(x: 730, y: 0, width: 570, height: 800)
        let area = EditorPanes.owlArea(textPane: text, chat: chat)
        #expect(area == CGRect(x: 0, y: 0, width: 730, height: 800))
        #expect(!area.intersects(chat))
        // Chat on the leading side (right-to-left).
        let rtl = EditorPanes.owlArea(textPane: text, chat: CGRect(x: 0, y: 0, width: 570, height: 800))
        #expect(rtl.minX == 570)
        // No chat, or one elsewhere: unchanged.
        #expect(EditorPanes.owlArea(textPane: text, chat: nil) == text)
        #expect(EditorPanes.owlArea(textPane: CGRect(x: 0, y: 0, width: 500, height: 800), chat: chat).width == 500)
        // No room left: nowhere (he hides).
        #expect(EditorPanes.owlArea(textPane: CGRect(x: 700, y: 0, width: 100, height: 800), chat: chat, minSize: 44) == .zero)
    }

    @Test func owlHiddenOnTheChatAndInFocus() {
        let wide = EditorPanes.layout(previewOn: false, askOpen: true, focus: false, regularWidth: true)
        let chat = CGRect(x: 730, y: 0, width: 570, height: 800)
        #expect(EditorPanes.owlHidden(layout: wide, owlFrame: CGRect(x: 1220, y: 720, width: 44, height: 44), chat: chat))
        #expect(!EditorPanes.owlHidden(layout: wide, owlFrame: CGRect(x: 660, y: 720, width: 44, height: 44), chat: chat))
        let focus = EditorPanes.layout(previewOn: true, askOpen: false, focus: true, regularWidth: false)
        #expect(EditorPanes.owlHidden(layout: focus, owlFrame: .zero, chat: nil))
        // Folded with the preview on (not focus): he stays, as before.
        let folded = EditorPanes.layout(previewOn: true, askOpen: false, focus: false, regularWidth: false)
        #expect(!EditorPanes.owlHidden(layout: folded, owlFrame: CGRect(x: 0, y: 0, width: 44, height: 44), chat: nil))
    }

    @Test func statusBarRestsAboveTheHomeIndicatorAndRidesADockedKeyboard() {
        // Keyboard hidden: the guide is a zero-height line on the safe area
        // (iOS 26). The bar rests just above the inset.
        #expect(EditorPanes.statusBarBottom(viewHeight: 800, keyboardTop: 766, keyboardBottom: 766, homeInset: 34) == 762)
        // Guide already at the screen edge.
        #expect(EditorPanes.statusBarBottom(viewHeight: 800, keyboardTop: 800, keyboardBottom: 800, homeInset: 34) == 762)
        // A home-indicator-tall guide that does reach the bottom is still not a keyboard.
        #expect(EditorPanes.statusBarBottom(viewHeight: 800, keyboardTop: 766, keyboardBottom: 800, homeInset: 34) == 762)
        // Docked keyboard.
        #expect(EditorPanes.statusBarBottom(viewHeight: 800, keyboardTop: 500, keyboardBottom: 800, homeInset: 34) == 500)
        // iPhone landscape: shorter keyboard, smaller home inset.
        #expect(EditorPanes.statusBarBottom(viewHeight: 390, keyboardTop: 230, keyboardBottom: 390, homeInset: 21) == 230)
        // Landscape, keyboard down.
        #expect(EditorPanes.statusBarBottom(viewHeight: 390, keyboardTop: 369, keyboardBottom: 369, homeInset: 21) == 365)
        // Floating keyboard: the bottom of the view stays clear.
        #expect(EditorPanes.statusBarBottom(viewHeight: 800, keyboardTop: 200, keyboardBottom: 420, homeInset: 34) == 762)
        // Guide not laid out yet.
        #expect(EditorPanes.statusBarBottom(viewHeight: 800, keyboardTop: 0, keyboardBottom: 0, homeInset: 0) == 800)
        #expect(EditorPanes.statusBarBottom(viewHeight: 0, keyboardTop: 0, keyboardBottom: 0, homeInset: 0) == 0)
    }
}
