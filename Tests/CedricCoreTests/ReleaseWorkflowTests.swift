import Foundation
import Testing

/// .github/workflows/release.yml builds only an existing tag: the checkout
/// is refs/tags/<TAG> exactly, and its "Check the tag" step (run here under
/// bash, with a stub `gh` answering the GitHub API) refuses a manual run
/// whose input is a branch, a commit or a tag that doesn't exist.
@Suite struct ReleaseWorkflowTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let workflow = (try? String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)) ?? ""

    /// The `run: |` block of the step named `name`, unindented.
    static func runBlock(of name: String) -> String? {
        let lines = workflow.components(separatedBy: "\n")
        guard let n = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "- name: \(name)" }),
              let r = lines[n...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "run: |" })
        else { return nil }
        var body: [String] = []
        var indent: Int?
        for line in lines[(r + 1)...] {
            let lead = line.prefix { $0 == " " }.count
            if line.trimmingCharacters(in: .whitespaces).isEmpty { body.append(""); continue }
            if indent == nil { indent = lead }
            guard lead >= indent! else { break }
            body.append(String(line.dropFirst(indent!)))
        }
        return body.joined(separator: "\n")
    }

    @Test func theCheckoutIsTheTagRefNotWhateverTheInputNames() {
        #expect(Self.workflow.contains("ref: refs/tags/${{ env.TAG }}"))
        #expect(!Self.workflow.contains("ref: ${{ env.TAG }}"))
        #expect(Self.workflow.contains("- name: Check the checkout is the tag"))
        // Still a draft, attached to that tag.
        #expect(Self.workflow.contains("draft: true"))
        #expect(Self.workflow.contains("tag_name: ${{ env.TAG }}"))
    }

    /// Runs the step with TAG and the event; `tags` are the refs the stub
    /// API has (anything else is a 404, as GitHub's git/ref is).
    static func check(tag: String, event: String = "workflow_dispatch", ref: String = "refs/heads/main",
                      tags: [String]) throws -> (Int32, String) {
        let script = try #require(runBlock(of: "Check the tag"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("owlink-wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // gh api repos/OWNER/REPO/git/ref/tags/NAME --jq .ref
        let gh = """
            #!/bin/bash
            path=$2; name=${path#*/git/ref/tags/}
            for t in \(tags.map { "'\($0)'" }.joined(separator: " ")); do
                [ "$t" = "$name" ] && { echo "refs/tags/$t"; exit 0; }
            done
            echo '{"message":"Not Found"}' >&2; exit 1
            """
        try gh.write(to: tmp.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.appendingPathComponent("gh").path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-e", "-c", script]
        p.environment = ["PATH": "\(tmp.path):/usr/bin:/bin", "TAG": tag, "GITHUB_EVENT_NAME": event,
                         "GITHUB_REF": ref, "GITHUB_REPOSITORY": "owner/repo", "GH_TOKEN": "unused"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func anExistingTagPasses() throws {
        let (rc, out) = try Self.check(tag: "v0.6.1", tags: ["v0.6.1"])
        #expect(rc == 0, "\(out)")
        let (rc2, out2) = try Self.check(tag: "v0.6.1-rc1", event: "push", ref: "refs/tags/v0.6.1-rc1", tags: ["v0.6.1-rc1"])
        #expect(rc2 == 0, "\(out2)")
    }

    @Test func aBranchACommitOrAMissingTagIsRefused() throws {
        for (tag, why) in [("main", "a branch"), ("9176eff31d5ef02e9248b508034fe678ab00b7ba", "a commit"),
                           ("v0.6.1", "a tag that doesn't exist (maybe a branch named v0.6.1)"),
                           ("v0.6.1;rm", "not a tag name"), ("", "empty")] {
            let (rc, out) = try Self.check(tag: tag, tags: ["v0.6.0", "v0.6.10"])
            #expect(rc != 0, "\(why): \(out)")
        }
    }

    @Test func aPushMustBeThatVeryTag() throws {
        let (rc, out) = try Self.check(tag: "v0.6.1", event: "push", ref: "refs/heads/v0.6.1", tags: ["v0.6.1"])
        #expect(rc != 0, "\(out)")
    }
}
