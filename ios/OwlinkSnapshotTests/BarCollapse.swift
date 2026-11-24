import XCTest
import UIKit

/// Which of the editor's bar buttons UIKit may move out of a narrow
/// navigation bar into the ••• menu, by their visibility priorities: every
/// set it can collapse, whatever the bar's width, Undo and Redo included.
///
/// Not measured here: the test host runs without a window scene, and its
/// bar collapses every button at any width (375, 402 and 440 pt alike, a
/// probe on 2026-11-24), which no iPhone does. Which buttons an iPhone 17
/// Pro really collapses is read in the UI test (testOverflowMenuScreenshots).
@MainActor
enum BarCollapse {
    /// Every set of bar buttons UIKit may collapse, by visibility priority:
    /// a button goes only once every button of a lower priority has gone
    /// (buttons of one priority in any order), from none to all of them.
    static func collapseSets(_ items: [UIBarButtonItem]) -> [[UIBarButtonItem]] {
        guard #available(iOS 27.0, *) else { return [[], items] }
        var sets: [[UIBarButtonItem]] = []
        for mask in 0..<(1 << items.count) {
            let set = items.indices.filter { mask & (1 << $0) != 0 }
            let kept = items.indices.filter { mask & (1 << $0) == 0 }
            let closed = set.allSatisfy { i in kept.allSatisfy { items[$0].visibilityPriority.rawValue >= items[i].visibilityPriority.rawValue } }
            if closed { sets.append(set.map { items[$0] }) }
        }
        return sets
    }
}
