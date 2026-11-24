import Foundation
import Testing
@testable import CedricCore

/// Citations kept to the lines a model was given, the planner covering
/// every line at any size, and the section notes in an exported chat.
@Suite struct OwlCitationsTests {
    static let lines1to18 = IndexSet(integersIn: 1...18)

    @Test func unsentLinesAreDroppedAndSentOnesKept() {
        // What Summarise answered on iPad, shown lines 1–18 of 282.
        let answer = """
        - Line 3 names the trip.
        - Lines 12–14 describe the walk.
        - Lines 19–20 talk about the rain.
        - Lines 31-34 end the day.
        """
        let f = OwlCitations.filter(answer, allowed: Self.lines1to18)
        #expect(f.text.contains("Line 3 names the trip."))
        #expect(f.text.contains("Lines 12–14 describe the walk."))
        #expect(!f.text.contains("rain") && !f.text.contains("end the day"))
        #expect(f.dropped == [19...20, 31...34] && f.flagged.isEmpty)
    }

    @Test func aSentenceThatAlsoCitesSentLinesIsFlaggedNotCut() {
        let one = "The opening (line 2) sets the scene and the ending on line 31 resolves it."
        let f = OwlCitations.filter(one, allowed: Self.lines1to18)
        #expect(f.text == "The opening (line 2) sets the scene and the ending on line 31\(OwlCitations.flag) resolves it.")
        #expect(f.flagged == [31...31] && f.dropped.isEmpty)
        // A range running past the lines given is flagged too.
        let over = OwlCitations.filter("Lines 17-20 repeat the list.", allowed: Self.lines1to18)
        #expect(over.text.contains("17-20\(OwlCitations.flag)"))
    }

    @Test func anAnswerThatIsOnlyAboutUnsentLinesIsFlaggedNotEmptied() {
        let f = OwlCitations.filter("- Lines 31–34 end the day.", allowed: Self.lines1to18)
        #expect(f.text == "- Lines 31–34\(OwlCitations.flag) end the day.")
    }

    @Test func formsItReads() {
        let cites = OwlCitations.find("See lines 3, 7 and 9-11, line 4 to 5.\n31| quoted text")
        #expect(cites.map(\.lines) == [3...3, 7...7, 9...11, 4...5, 31...31])
        // Not citations: a count of lines, a heading number, a time, L2/L1 terms.
        #expect(OwlCitations.find("It has 282 lines. ## 2 Plans at 12:30, #4. L2 regularization, an L1 cache.").isEmpty)
        // A list stops at a number that doesn't end a clause.
        #expect(OwlCitations.find("On line 5, 2026 changed it.").map(\.lines) == [5...5])
        #expect(OwlCitations.find("Line 3, 100 items are read.").map(\.lines) == [3...3])
        #expect(OwlCitations.filter("Nothing cited here.", allowed: IndexSet()).changed == false)
    }

    @Test func numbersJoinedByAndAndListedFindingsAreRead() {
        // "and" lists the next number whatever follows it.
        #expect(OwlCitations.find("Lines 3 and 31 describe the walk.").map(\.lines) == [3...3, 31...31])
        #expect(OwlCitations.find("Lines 3 & 31-33 describe it.").map(\.lines) == [3...3, 31...33])
        let f = OwlCitations.filter("Lines 3 and 31 describe the walk.", allowed: Self.lines1to18)
        #expect(f.text == "Lines 3 and 31\(OwlCitations.flag) describe the walk.")
        // A finding listed by its line number.
        #expect(OwlCitations.find("- 31: an unchecked download\n* 12-14: eval of input").map(\.lines) == [31...31, 12...14])
        let items = OwlCitations.filter("- 12: First\n- 31: Second", allowed: Self.lines1to18)
        #expect(items.text == "- 12: First" && items.dropped == [31...31])
        // Still not citations: L2, a date after a comma, a time in a list item.
        #expect(OwlCitations.find("L2 regularization. - 12:30 standup").isEmpty)
        #expect(OwlCitations.find("On line 5, 2026 changed it.").map(\.lines) == [5...5])
        // A flagged citation is no evidence for its line.
        #expect(OwlCitations.evidence(in: "Line 4 and line 31\(OwlCitations.flag) differ.") == IndexSet(integer: 4))
        #expect(OwlCitations.quotedLines(in: "12| a match\n40| another\n(3 more lines match)") == IndexSet([12, 40]))
    }

    @Test func aStreamShowsCitationsOnlyOnceChecked() {
        let answer = "The walk (2026) starts.\n- Lines 19–20 talk about rain.\nLines 3 and 31 describe it.\n31| quoted\nLine 4 ends"
        // Fed in small pieces, as a model streams.
        var stream = OwlCitations.Stream()
        var shown: [String] = []
        var i = answer.startIndex
        while i < answer.endIndex {
            let j = answer.index(i, offsetBy: 3, limitedBy: answer.endIndex) ?? answer.endIndex
            shown.append(stream.feed(String(answer[i..<j]), allowed: Self.lines1to18))
            i = j
        }
        // Before the end: what was shown never has an unchecked citation of 19, 20 or 31.
        let before = shown.joined()
        for c in OwlCitations.find(before) where !Self.lines1to18.contains(integersIn: c.lines) {
            let end = NSMaxRange(c.range)
            #expect((before as NSString).substring(from: end).hasPrefix(OwlCitations.flag), "\(c.lines)")
        }
        #expect(!before.contains("Line 4"))  // held: its line hasn't ended
        // Text before a number shows at once; a number not after "line" passes.
        #expect(before.hasPrefix("The walk (2026) starts.\n- "))
        let all = before + stream.finish(allowed: Self.lines1to18)
        #expect(all == "The walk (2026) starts.\n- Lines 19–20\(OwlCitations.flag) talk about rain.\n"
                + "Lines 3 and 31\(OwlCitations.flag) describe it.\n31\(OwlCitations.flag)| quoted\nLine 4 ends")
        // No filter: everything passes as it came.
        var open = OwlCitations.Stream()
        #expect(open.feed("Line 31 x", allowed: nil) == "Line 31 x" && open.finish(allowed: nil).isEmpty)
    }

    /// "\r\n" is one Character in Swift: it still ends the line, so a
    /// quoted "31|" after it is held and checked like any other.
    @Test func aStreamTreatsCRLFAsALineBreak() {
        for answer in ["Overview.\r\n31| quoted\r\nEnd.", "Overview.\r31| quoted\rEnd."] {
            for size in [1, 3, 11, answer.count] {
                var stream = OwlCitations.Stream()
                var shown = ""
                var i = answer.startIndex
                while i < answer.endIndex {
                    let j = answer.index(i, offsetBy: size, limitedBy: answer.endIndex) ?? answer.endIndex
                    shown += stream.feed(String(answer[i..<j]), allowed: Self.lines1to18)
                    i = j
                }
                #expect(!shown.contains("31|"), "\(size): \(shown.debugDescription)")
                #expect(shown.contains("31\(OwlCitations.flag)|"), "\(size): \(shown.debugDescription)")
                #expect(!(shown + stream.finish(allowed: Self.lines1to18)).contains("31|"))
            }
        }
    }

    /// Fed to a stream in pieces of `size` characters; what was shown
    /// before the end, and everything shown.
    static func streamed(_ answer: String, size: Int, allowed: IndexSet) -> (before: String, all: String) {
        var stream = OwlCitations.Stream()
        var shown = ""
        var i = answer.startIndex
        while i < answer.endIndex {
            let j = answer.index(i, offsetBy: size, limitedBy: answer.endIndex) ?? answer.endIndex
            shown += stream.feed(String(answer[i..<j]), allowed: allowed)
            i = j
        }
        return (shown, shown + stream.finish(allowed: allowed))
    }

    /// A citation that runs onto the next row is checked whole: "Line 4
    /// through" / "9999" is lines 4–9999, not line 4 and a stray number.
    /// 0.5.3's follow-up checked one row at a time, showed it unflagged,
    /// and so made lines 4–9999 evidence for the combine call.
    @Test func aCitationAcrossARowBreakIsCheckedWhole() {
        for brk in ["\n", "\r\n"] {
            for join in [" through", " to", " -", ","] {
                let lead = join == "," ? "Lines 4" : "Line 4"
                let tail = join == "," ? "9999; it describes the setup." : "9999 describes the setup."
                let answer = "Overview.\(brk)\(lead)\(join)\(brk)\(tail)\(brk)The end."
                let f = OwlCitations.filter(answer, allowed: Self.lines1to18)
                #expect(f.text.contains("9999\(OwlCitations.flag)"), "\(answer.debugDescription) → \(f.text.debugDescription)")
                // Flagged, the citation is evidence for nothing beyond the lines given.
                #expect(OwlCitations.evidence(in: f.text).isSubset(of: Self.lines1to18), "\(answer.debugDescription)")
                for size in [1, 2, 3, 7, answer.count] {
                    let (before, all) = Self.streamed(answer, size: size, allowed: Self.lines1to18)
                    // Never shown unflagged, even before the end.
                    for c in OwlCitations.find(before) where !Self.lines1to18.contains(integersIn: c.lines) {
                        #expect((before as NSString).substring(from: NSMaxRange(c.range)).hasPrefix(OwlCitations.flag),
                                "\(size): \(before.debugDescription)")
                    }
                    #expect(!before.contains("9999 describes") && !before.contains("9999;"), "\(size): \(before.debugDescription)")
                    #expect(all == f.text, "\(size): \(all.debugDescription)")
                }
            }
        }
        // After a citation held across rows, a later one on the same row is still checked,
        // and odd spacing in ", and" still holds the row.
        for answer in ["Line 4 through\n9999 describes line 77.", "See lines 3 and\n31 describe line 77.",
                       "lines 3,  and\n9999 describe it.", "lines 3,\tand\r\n9999 describe it."] {
            let f = OwlCitations.filter(answer, allowed: IndexSet([3, 4]))
            for size in [1, 2, 5, answer.count] {
                let (before, all) = Self.streamed(answer, size: size, allowed: IndexSet([3, 4]))
                for c in OwlCitations.find(before) where !IndexSet([3, 4]).contains(integersIn: c.lines) {
                    #expect((before as NSString).substring(from: NSMaxRange(c.range)).hasPrefix(OwlCitations.flag),
                            "\(size): \(before.debugDescription)")
                }
                #expect(all == f.text, "\(size): \(all.debugDescription) vs \(f.text.debugDescription)")
            }
        }
        // Wholly inside the lines given, it passes untouched.
        let fine = "Line 4 through\n18 describes the setup."
        #expect(OwlCitations.filter(fine, allowed: Self.lines1to18).text == fine)
        #expect(Self.streamed(fine, size: 2, allowed: Self.lines1to18).all == fine)
        // A row break before a dash, "and" or "to", or right after "line",
        // ends the citation: a list item below is not a range's end.
        #expect(OwlCitations.find("See line 4\n- 5: an item").map(\.lines) == [4...4, 5...5])
        #expect(OwlCitations.find("See line 4\nand 31 more").map(\.lines) == [4...4])
        #expect(OwlCitations.find("Several lines\n31 rows").isEmpty)
    }

    /// A list item taken out must not leave the rows around it reading as
    /// a citation the answer never made: "Line 4 through" / "9999
    /// describes" once the line-99 item between them is gone is lines
    /// 4–9999. 0.5.4's follow-up 4 joined them and so vouched for 4–9999.
    @Test func droppingAnItemNeverJoinsTheRowsAroundItIntoACitation() {
        for brk in ["\n", "\r\n"] {
            for (lead, tail) in [("Line 4 through", "9999 describes the setup."), ("See lines 3 and", "31 describe it."),
                                 ("- 4", "–31: setup"), ("Line 4 -", "9999 describes the setup.")] {
                let answer = "\(lead)\(brk)- Line 99: unrelated.\(brk)\(tail)"
                let f = OwlCitations.filter(answer, allowed: Self.lines1to18)
                // Nothing vouched for beyond the lines given, and nothing cited that the answer didn't cite.
                #expect(OwlCitations.evidence(in: f.text).isSubset(of: Self.lines1to18), "\(answer.debugDescription) → \(f.text.debugDescription)")
                let before = Set(OwlCitations.find(answer).map(\.lines))
                for c in OwlCitations.find(f.text) {
                    #expect(before.contains(c.lines), "\(answer.debugDescription) → \(f.text.debugDescription)")
                }
                // The item stays, flagged, rather than join them.
                #expect(f.text.contains("Line 99\(OwlCitations.flag): unrelated.") && f.dropped.isEmpty, "\(f.text.debugDescription)")
            }
        }
        // Where the rows around it join into nothing, the item still goes.
        let plain = OwlCitations.filter("Overview.\n- Line 99: unrelated.\nLine 4 describes the setup.", allowed: Self.lines1to18)
        #expect(plain.text == "Overview.\nLine 4 describes the setup." && plain.dropped == [99...99])
    }

    /// "- 4" / "–31: setup" is item 4–31 to `find`, so the stream holds
    /// the "4" at its row's end until the next row shows whether a dash
    /// comes. 0.5.4's follow-up 4 showed "31: setup" unflagged.
    @Test func aStreamHoldsAListItemsNumberForADashOnTheNextRow() {
        for answer in ["- 4\n–31: setup", "- 4\r\n–31: setup", "* 4\n\n— 31: setup", "Overview.\n- 4\n-31: setup\nThe end.",
                       "-\n4\n–31: setup", "- 4\n- Line 99: x, line 2\nLine 2 ok"] {
            let f = OwlCitations.filter(answer, allowed: Self.lines1to18)
            for size in [1, 2, 3, 5, answer.count] {
                let (before, all) = Self.streamed(answer, size: size, allowed: Self.lines1to18)
                for c in OwlCitations.find(before) where !Self.lines1to18.contains(integersIn: c.lines) {
                    #expect((before as NSString).substring(from: NSMaxRange(c.range)).hasPrefix(OwlCitations.flag),
                            "\(size): \(before.debugDescription)")
                }
                #expect(!before.contains("31: setup"), "\(size): \(before.debugDescription)")
                // The stream flags what the finished answer flags (it drops nothing: none of these is dropped).
                #expect(all == f.text, "\(size): \(all.debugDescription) vs \(f.text.debugDescription)")
            }
        }
        // A row that is only a list marker, kept as context, doesn't stop the next row's item being held.
        for answer in ["Findings:\n-\n- 31: setup is wrong.", "*\n* 40: missing check\n", "*   \r\n* 41| quoted",
                       "• \n\n• \n\n31: x", "-\n\n- Line 31 too."] {
            let f = OwlCitations.filter(answer, allowed: Self.lines1to18)
            #expect(f.changed, "\(answer.debugDescription)")
            for size in [1, 2, 3, answer.count] {
                let (before, all) = Self.streamed(answer, size: size, allowed: Self.lines1to18)
                for c in OwlCitations.find(before) where !Self.lines1to18.contains(integersIn: c.lines) {
                    #expect((before as NSString).substring(from: NSMaxRange(c.range)).hasPrefix(OwlCitations.flag),
                            "\(size): \(before.debugDescription)")
                }
                #expect(OwlCitations.evidence(in: all).isSubset(of: Self.lines1to18), "\(size): \(all.debugDescription)")
                if f.dropped.isEmpty { #expect(all == f.text, "\(size): \(all.debugDescription) vs \(f.text.debugDescription)") }
            }
        }
        #expect(OwlCitations.filter("- 4\n–31: setup", allowed: Self.lines1to18).text == "- 4\n–31\(OwlCitations.flag): setup")
        // A number held for a dash that doesn't come is shown as it was.
        for size in [1, 3] {
            #expect(Self.streamed("- 4\nThe end.", size: size, allowed: Self.lines1to18).all == "- 4\nThe end.")
            #expect(Self.streamed("- 4\nLine 31 too.", size: size, allowed: Self.lines1to18).all
                    == "- 4\nLine 31\(OwlCitations.flag) too.")
        }
    }

    /// "line 5, 2026" is line 5 and a year, at the end of the text too.
    @Test func aBareCommaAfterSingularLineListsNothing() {
        for text in ["On line 5, 2026", "On line 5, 2026\n", "On line 5, 2026.", "Line 3, 100"] {
            #expect(OwlCitations.find(text).count == 1, "\(text.debugDescription)")
        }
        #expect(OwlCitations.find("On line 5, 2026").map(\.lines) == [5...5])
        // Not shown as an unread line 2026 either.
        #expect(OwlCitations.filter("On line 5, 2026", allowed: Self.lines1to18).changed == false)
        // "lines" still lists with commas, and "line … and" still joins.
        #expect(OwlCitations.find("See lines 3, 7.").map(\.lines) == [3...3, 7...7])
        #expect(OwlCitations.find("See line 3 and 7.").map(\.lines) == [3...3, 7...7])
        #expect(OwlCitations.find("See line 3, 7 and 9-11.").map(\.lines) == [3...3, 7...7, 9...11])
        #expect(OwlCitations.find("See line 3, 5, 7, and 9").map(\.lines) == [3...3, 5...5, 7...7, 9...9])
        #expect(OwlCitations.find("L2 regularization").isEmpty)
    }

    @Test func ordinaryProseIsNeverCutOnlyFlagged() {
        // Selection 40–60; paragraphs (not list items) about other lines keep their words.
        let allowed = IndexSet(integersIn: 40...60)
        let text = "This uses L2 regularization on line 45.\n\nThe setup on line 2 matters too.\n\n\n    indented code"
        let f = OwlCitations.filter(text, allowed: allowed)
        #expect(f.text == "This uses L2 regularization on line 45.\n\nThe setup on line 2\(OwlCitations.flag) matters too.\n\n\n    indented code")
        #expect(f.dropped.isEmpty && f.flagged == [2...2])
        // Nothing out of range: the text is returned exactly.
        let clean = "\n  code\n\n\n\nLine 45 is fine.\n"
        #expect(OwlCitations.filter(clean, allowed: allowed).text == clean)
    }

    @Test func zeroBasedOrShiftedCitationsAreCaught() {
        // A 0-based "line 0", or a citation shifted one past the last line given.
        let f = OwlCitations.filter("- Line 0 is the front matter.\n- Line 19 is the title.\n- Line 1 opens it.",
                                    allowed: Self.lines1to18)
        #expect(f.text == "- Line 1 opens it.")
        #expect(f.dropped == [0...0, 19...19])
    }

    @Test func numberingCountsFrontMatterSoCitationsAreNotOffset() {
        // Line numbers sent are the file's own: front matter is line 1, not skipped.
        let text = "---\ntitle: Field notes\n---\n# Day one\nWe walked.\n"
        let s = OwlDocumentSnapshot(text: text, generation: 1, fileName: "n.md", language: "markdown")
        #expect(s.countedLines == 5)
        #expect(s.numbered(lines: 1, 5).components(separatedBy: "\n") == ["1| ---", "2| title: Field notes", "3| ---", "4| # Day one", "5| We walked."])
        let part = OwlChatContext.reviewPart(s, first: 4, last: 5)
        #expect(part.numbered == "4| # Day one\n5| We walked.")
        #expect(OwlCitations.lines(in: part.numbered) == IndexSet(integersIn: 4...5))
        let whole = OwlChatContext.build(s, scope: .wholeDocument, budget: 10_000)!
        #expect(whole.firstLine == 1 && whole.lastLine == 5 && !whole.truncated)
    }

    @Test(arguments: [(2_000, 400), (5_000, 600), (5_000, 3_000)])
    func planCoversEveryLineAtBigSizes(lines n: Int, budget: Int) {
        let text = (1...n).map { "line \($0) " + String(repeating: "t", count: 10 + $0 % 40) }.joined(separator: "\n")
        let s = OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: (text as NSString).length / 2, length: 0))
        let plan = OwlChunkedReview.plan(s, budget: budget)
        #expect(plan.totalLines == n && plan.isComplete)
        #expect(plan.parts.first?.first == 1 && plan.parts.last?.last == n)
        #expect(plan.parts.allSatisfy { $0.fits && ($0.numbered as NSString).length <= budget })
        for (a, b) in zip(plan.parts, plan.parts.dropFirst()) { #expect(b.first > a.first && b.first <= a.last + 1) }
        #expect(OwlChunkedReview.label(plan) == String(localized: "Whole document (\(n) lines)"))
    }

    @Test func sectionNotesExportUnderTheAnswer() {
        let entry = OwlChatEntry(role: .owl, text: "One answer.",
                                 sections: [OwlChatSection(first: 1, last: 40, text: "Notes A"), OwlChatSection(first: 39, last: 80, text: "Notes B")])
        let md = OwlChatEntry.markdown([entry], fileName: "n.md")
        #expect(md.contains("**Cedric:** One answer.\n"))
        #expect(md.contains("<summary>Section notes (2)</summary>"))
        #expect(md.contains("**Lines 1–40:** Notes A") && md.contains("**Lines 39–80:** Notes B"))
        #expect(md.range(of: "One answer.")!.lowerBound < md.range(of: "Notes A")!.lowerBound)
    }

    /// A list marker alone on a row, after a citation held across rows
    /// ("lines 3 and" / " - " / "99:"), stays with the next row: `filter`
    /// reads " - " / "99:" as citing line 99, and so must the stream.
    /// 0.5.4's follow-up 5 released at the dash's row end, forgot the
    /// marker, and showed "99:" unflagged.
    @Test func aStreamKeepsAListMarkerRowAfterAHeldCitation() {
        for answer in ["Line 4 -See lines 3 and\r\n - \n99:", "Line 4 -See lines 3 and\n - \n99: x", "See lines 3 and\n*\n99: setup."] {
            let f = OwlCitations.filter(answer, allowed: Self.lines1to18)
            #expect(f.text.contains("99\(OwlCitations.flag):"), "\(answer.debugDescription) → \(f.text.debugDescription)")
            for size in [1, 2, 3, 5, answer.count] {
                let (before, all) = Self.streamed(answer, size: size, allowed: Self.lines1to18)
                for c in OwlCitations.find(before) where !Self.lines1to18.contains(integersIn: c.lines) {
                    #expect((before as NSString).substring(from: NSMaxRange(c.range)).hasPrefix(OwlCitations.flag),
                            "\(size): \(before.debugDescription)")
                }
                #expect(all.contains("99\(OwlCitations.flag):"), "\(size): \(all.debugDescription)")
                #expect(all == f.text, "\(size): \(all.debugDescription) vs \(f.text.debugDescription)")
            }
        }
    }

    /// Filtering twice flags once: the chat runner flags "Line 999" and
    /// the whole-document runner filters its answer again. 0.5.4's
    /// follow-up 5 put a second flag after it.
    @Test func filteringTwiceFlagsOnce() {
        for answer in ["Line 999 describes setup.", "Overview.\n- Line 999 and line 2: setup.\nLine 31, line 4 too.",
                       "- 4\n–31: setup", "Line 4 through\n9999 describes the setup."] {
            let once = OwlCitations.filter(answer, allowed: Self.lines1to18)
            #expect(once.changed, "\(answer.debugDescription)")
            for allowed in [Self.lines1to18, IndexSet(integersIn: 1...4)] {
                let twice = OwlCitations.filter(once.text, allowed: allowed)
                #expect(twice.text.components(separatedBy: OwlCitations.flag).count
                        == once.text.components(separatedBy: OwlCitations.flag).count + twice.flagged.count,
                        "\(once.text.debugDescription) → \(twice.text.debugDescription)")
                #expect(!twice.text.contains(OwlCitations.flag + OwlCitations.flag), "\(twice.text.debugDescription)")
            }
            #expect(OwlCitations.filter(once.text, allowed: Self.lines1to18) == OwlCitations.Filtered(text: once.text, dropped: [], flagged: []))
        }
        #expect(OwlCitations.filter("Line 999 describes setup.", allowed: Self.lines1to18).text
                == "Line 999\(OwlCitations.flag) describes setup.")
        // A stream fed text already flagged doesn't flag it again either.
        let flagged = "Line 999\(OwlCitations.flag) describes setup."
        for size in [1, 4, flagged.count] {
            #expect(Self.streamed(flagged, size: size, allowed: Self.lines1to18).all == flagged)
        }
    }

    /// A citation the chat runner flagged still counts when the part's
    /// filter decides whether an item is about lines it read: "Line 4
    /// through 99" touches line 4, so the item stays, though its other
    /// citation (line 31, citable from the conversation but not in the
    /// part) is not in the part. 0.5.4's follow-up 6 left the flagged span
    /// out of that check and dropped the item.
    @Test func aSecondFilterKeepsAnItemWhoseFlaggedSpanTouchesTheLinesRead() {
        let answer = "Overview.\n- Line 4 through 99 and line 31: setup."
        let chat = OwlCitations.filter(answer, allowed: Self.lines1to18.union(IndexSet(integer: 31)))
        #expect(chat.text == "Overview.\n- Line 4 through 99\(OwlCitations.flag) and line 31: setup.")
        let part = OwlCitations.filter(chat.text, allowed: Self.lines1to18)
        #expect(part.text == "Overview.\n- Line 4 through 99\(OwlCitations.flag) and line 31\(OwlCitations.flag): setup.",
                "\(part.text.debugDescription)")
        #expect(part.dropped.isEmpty && part.flagged == [31...31])
        #expect(part.text.components(separatedBy: OwlCitations.flag).count == 3)
        #expect(!part.text.contains(OwlCitations.flag + OwlCitations.flag))
        // Read again, it is left as it is.
        #expect(OwlCitations.filter(part.text, allowed: Self.lines1to18) == OwlCitations.Filtered(text: part.text, dropped: [], flagged: []))
        // An item whose every citation, flagged or not, misses the lines
        // read is still dropped.
        let elsewhere = OwlCitations.filter("Overview.\n- Line 40 through 99\(OwlCitations.flag) and line 31: setup.", allowed: Self.lines1to18)
        #expect(elsewhere.text == "Overview.")
    }

    /// An item dropped by the part's filter takes its indented rows with
    /// it, even one whose citation the chat runner already flagged:
    /// "Line 31" was citable from the conversation, "Line 42" was not,
    /// and the part read neither. 0.5.4's follow-up 7 counted the flagged
    /// citation as the row's own and left "Line 42" behind, under no item.
    @Test func aDroppedItemTakesItsFlaggedContinuationWithIt() {
        let answer = "Overview.\n- Line 31: setup.\n  Line 42: detail."
        let chat = OwlCitations.filter(answer, allowed: Self.lines1to18.union(IndexSet(integer: 31)))
        #expect(chat.text == "Overview.\n- Line 31: setup.\n  Line 42\(OwlCitations.flag): detail.")
        let part = OwlCitations.filter(chat.text, allowed: Self.lines1to18)
        #expect(part.text == "Overview.", "\(part.text.debugDescription)")
        #expect(part.dropped == [31...31] && part.flagged.isEmpty)
        // Unflagged, the same: the indented row is about lines not read.
        let direct = OwlCitations.filter(answer, allowed: Self.lines1to18)
        #expect(direct.text == "Overview.", "\(direct.text.debugDescription)")
        #expect(direct.dropped == [31...31, 42...42])
        // An indented row citing a line read is not part of what was dropped.
        let read = OwlCitations.filter("Overview.\n- Line 31: setup.\n  Line 5: detail.", allowed: Self.lines1to18)
        #expect(read.text == "Overview.\n  Line 5: detail.", "\(read.text.debugDescription)")
        // The mixed item is still kept, flagged once on its span.
        let mixed = OwlCitations.filter(OwlCitations.filter("Overview.\n- Line 4 through 99 and line 31: setup.\n  Line 42: detail.",
                                                            allowed: Self.lines1to18.union(IndexSet(integer: 31))).text,
                                        allowed: Self.lines1to18)
        #expect(mixed.text == "Overview.\n- Line 4 through 99\(OwlCitations.flag) and line 31\(OwlCitations.flag): setup.\n  Line 42\(OwlCitations.flag): detail.",
                "\(mixed.text.debugDescription)")
        #expect(!mixed.text.contains(OwlCitations.flag + OwlCitations.flag))
    }
}
