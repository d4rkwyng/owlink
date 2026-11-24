import Testing
@testable import CedricCore

/// The app, not the model, says an edit is only proposed until Apply.
@Suite struct OwlProposalWordingTests {
    @Test func fixedAndChangedReadAsProposals() {
        #expect(OwlProposalWording.guardClaims("Fixed 'definately' to 'definitely'.", proposals: 1)
                == "Proposed fix: 'definately' to 'definitely'.")
        #expect(OwlProposalWording.guardClaims("Changed line 22 to use guard.", proposals: 1)
                == "Proposed change: line 22 to use guard.")
        #expect(OwlProposalWording.guardClaims("Looks fine. Corrected the spelling on line 3.", proposals: 1)
                == "Looks fine. Proposed correction: the spelling on line 3.")
    }

    @Test func firstPersonAndPassiveClaims() {
        #expect(OwlProposalWording.guardClaims("I updated the header.", proposals: 1) == "I propose updating the header.")
        #expect(OwlProposalWording.guardClaims("I've fixed the typo.", proposals: 1) == "I propose fixing the typo.")
        #expect(OwlProposalWording.guardClaims("I have changed line 4.", proposals: 2) == "I propose changing line 4.")
        #expect(OwlProposalWording.guardClaims("The typo has been corrected.", proposals: 1)
                == "The typo would be corrected (once you press Apply).")
    }

    @Test func listItemsAndLineStarts() {
        let answer = "Two edits:\n- Fixed the loop bound.\n2. Replaced `i` with `index`."
        #expect(OwlProposalWording.guardClaims(answer, proposals: 2)
                == "Two edits:\n- Proposed fix: the loop bound.\n2. Proposed replacement: `i` with `index`.")
    }

    @Test func untouchedWithoutProposalsOrClaims() {
        let claim = "Fixed 'definately' to 'definitely'."
        #expect(OwlProposalWording.guardClaims(claim, proposals: 0) == claim)
        let plain = "Changes like this are common. The function was added in 2019."
        #expect(OwlProposalWording.guardClaims(plain, proposals: 1) == plain)
    }

    @Test func idempotent() {
        let once = OwlProposalWording.guardClaims("Fixed X to Y. I changed line 3.", proposals: 1)
        #expect(OwlProposalWording.guardClaims(once, proposals: 1) == once)
        #expect(!once.contains("Fixed") && !once.contains("changed"))
    }

    @Test func aCardReasonReadsAsAProposal() {
        #expect(OwlProposalWording.guardReason("Fixed the typo") == "Proposed fix: the typo")
        #expect(OwlProposalWording.guardReason("I changed the loop to a guard.") == "I propose changing the loop to a guard.")
        #expect(OwlProposalWording.guardReason("Typo in a comment") == "Typo in a comment")
        #expect(OwlProposalWording.guardReason("") == "")
    }

    @Test func headerAndBadge() {
        #expect(OwlProposalWording.badge == "Proposed, not applied")
        #expect(OwlProposalWording.header(count: 1) == "Proposed 1 change, not applied")
        #expect(OwlProposalWording.header(count: 3) == "Proposed 3 changes, not applied")
    }
}
