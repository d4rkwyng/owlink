import Foundation
import Testing
@testable import CedricCore

/// Prose detection: a corpus of writing that should count as prose
/// (emails, letters, notes, stories) and of text that must not (logs,
/// config, code pasted into a .txt, shopping lists, CSV).
@Suite struct ProseTests {
    static let prose: [String] = [
        // emails
        "Hi Sam,\n\nThanks for sending the report over. I had a look this morning and it reads well. Could you add the numbers from March before Friday?\n\nBest,\nDerek\n",
        "Hello team,\n\nJust a reminder that the office will be closed on Monday for the holiday. If you need anything urgent, please call me on my mobile.\n\nThanks,\nAnna\n",
        "Dear Mr. Patel,\n\nI am writing to follow up on our conversation last week about the lease. We would like to renew it for another year, if the terms are the same.\n\nKind regards,\nLucy Brown\n",
        "Their going too the store tomorrow and we was late. I think we should leave earlier next time, so we are not in a hurry.\n",
        "Hey! Are you free for lunch on Thursday? There is a new place near the station that I have wanted to try for a while.\n",
        // letters
        "Dear Grandma,\n\nThank you so much for the birthday card and the lovely scarf. It has been very cold here, so I wear it every day. I hope you are keeping well and that the garden is doing better this year.\n\nLove,\nEmma\n",
        "To whom it may concern,\n\nI have known Maria for five years, and in that time she has been a reliable and thoughtful colleague. I recommend her without hesitation for the position.\n",
        // notes
        "Meeting notes, 12 March\n\nWe agreed to move the launch to April. Tom will talk to the printer about the new date. The budget is fine for now, but we need to check it again in two weeks.\n",
        "Ideas for the weekend: we could go to the coast if the weather is good. Otherwise the museum has a new exhibition that the kids would enjoy.\n",
        "Remember to call the dentist on Monday. The appointment was moved, and I still have not heard back from them about the new time.\n",
        // stories
        "Once upon a time there was a small owl who lived in an old oak tree. Every night he watched the stars and wondered how far away they were.\n",
        "The rain had not stopped for three days. Maggie stood at the window and watched the river rise, slowly at first and then all at once.\n",
        "He opened the door and found the room exactly as he had left it. The books were still on the table, and the cup of tea had gone cold.\n",
        // Markdown prose
        "# Trip to Lisbon\n\nWe arrived on a Tuesday and the city was already warm. The trams were full, so we walked up the hill to the castle instead.\n\n## Food\n\nThe best meal was at a small place near the river. I would go back just for the bread.\n",
        "---\ntitle: My week\ndate: 2026-11-10\n---\n\nThis week was busy but good. I finished the **first draft** of the essay and sent it to my editor. She said the middle part is too long, and I think she is right.\n",
        "Here is what I learned today. The `git stash` command saves your changes for later, which is useful when you need to switch branches.\n\n```sh\ngit stash\ngit checkout main\n```\n\nIt is easy once you have done it a couple of times.\n",
        "- Call Sam about the invoice before Friday.\n- Ask the landlord when the heating will be fixed.\n- Book the train tickets for the wedding in June.\n",
        "Read more at https://example.com/blog/post-1 if you are interested. The author explains the history of the bridge and why it was built where it is.\n",
        // other languages
        "Bonjour Marie,\n\nJe voulais te dire que la réunion de demain est annulée. Nous pouvons la reprendre la semaine prochaine si tu es disponible.\n\nÀ bientôt,\nPaul\n",
        "Liebe Anna,\n\nvielen Dank für deine Nachricht. Ich bin morgen nicht im Büro, aber wir können am Freitag telefonieren, wenn es dir passt.\n\nViele Grüße\nTom\n",
        "Hola Carlos, gracias por la invitación. Me encantaría ir a la cena del sábado, pero tengo que trabajar hasta tarde. ¿Podemos vernos el domingo?\n",
        "I can't believe it's already November. The year went by so fast, and there is still so much I wanted to do before it ends.\n",
    ]

    static let notProse: [(String, String?)] = [
        // logs
        ("2026-11-18 10:42:01 INFO Server started on port 8080\n2026-11-18 10:42:02 WARN Cache is cold\n2026-11-18 10:42:05 ERROR Connection to the database failed: timeout\n2026-11-18 10:42:06 INFO Retrying in 5 seconds\n", nil),
        ("[INFO] Building project\n[INFO] Compiling 42 source files to the target folder\n[ERROR] Failed to resolve the dependency com.example:lib:1.2\n[INFO] BUILD FAILURE\n", nil),
        ("Nov 18 10:42:01 host sshd[1234]: Accepted publickey for droid from 10.0.0.5 port 50422\nNov 18 10:42:03 host sshd[1234]: pam_unix(sshd:session): session opened for user droid\n", nil),
        ("This is the application log and it is written by the server.\n", "server.log"),
        // config
        ("[server]\nport = 8080\nhost = 0.0.0.0\nlog_level = debug\n\n[database]\nurl = postgres://localhost/app\npool_size = 10\n", nil),
        ("name: cedric\nversion: 1.2.3\nenabled: true\nretries: 3\npaths:\n  - /usr/local/bin\n  - ~/bin\n", nil),
        ("export PATH=/usr/local/bin:$PATH\nexport EDITOR=\"cedric -w\"\nalias ll='ls -la'\n", nil),
        ("DATABASE_URL=postgres://user:pass@localhost/db\nSECRET_KEY=abc123\nDEBUG=false\nALLOWED_HOSTS=localhost,127.0.0.1\n", nil),
        // code pasted into a .txt
        ("func total(_ items: [Int]) -> Int {\n    var t = 0\n    for i in items { t += i }\n    return t\n}\n", "notes.txt"),
        ("def greet(name):\n    print(f\"Hello, {name}\")\n    return name.upper()\n\nif __name__ == \"__main__\":\n    greet(\"world\")\n", nil),
        ("#include <stdio.h>\n\nint main(void) {\n    printf(\"hello, world\\n\");\n    return 0;\n}\n", nil),
        ("const items = data.filter(x => x.active).map(x => x.name);\nconsole.log(items.length);\nexport default items;\n", nil),
        ("SELECT name, email FROM users WHERE created_at > '2026-01-01' ORDER BY name;\nUPDATE users SET active = 0 WHERE id = 42;\n", nil),
        ("<html>\n<head><title>Test</title></head>\n<body><p>Hello there, this is a page.</p></body>\n</html>\n", nil),
        ("{\"name\": \"Cedric\", \"kind\": \"owl\", \"hints\": [\"json\", \"tabs\"], \"n\": 42}\n", nil),
        // lists, tables
        ("eggs\nmilk\nbread\nbutter\ncoffee\napples\ntoilet paper\ndish soap\n", nil),
        ("- eggs\n- milk\n- bread\n- two lemons\n- something for dinner\n- the good cheese\n", nil),
        ("name,email,city\nAnna,anna@example.com,Lisbon\nTom,tom@example.com,Berlin\nSam,sam@example.com,Leeds\n", nil),
        ("id\tname\tqty\n1\tWidget\t4\n2\tGadget\t10\n3\tThing\t7\n", nil),
        ("A long sentence in a CSV file that has a lot of words in it, but it is still data.\n", "people.csv"),
        // diff and stack traces
        ("diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n-old line here\n+new line here\n", nil),
        ("Traceback (most recent call last):\n  File \"app.py\", line 10, in <module>\n    main()\n  File \"app.py\", line 6, in main\n    x = 1 / 0\nZeroDivisionError: division by zero\n", nil),
        // too short to say
        ("Hello there.\n", nil),
    ]

    @Test func proseCorpusCounts() {
        #expect(Self.prose.count >= 20)
        for (i, s) in Self.prose.enumerated() {
            let lang: Language = s.hasPrefix("#") || s.hasPrefix("---") || s.contains("```") || s.hasPrefix("- ") ? .markdown : .plain
            let ok = ProseDetector.isProse(s as NSString, language: lang, fileName: lang == .markdown ? "a.md" : "a.txt")
            let g = ProseDetector.signals(ProseMask.masked(s as NSString, language: lang))
            #expect(ok, "prose #\(i) not detected: \(g) \(s.prefix(40))")
        }
    }

    @Test func notProseCorpusDoesNot() {
        #expect(Self.notProse.count >= 20)
        for (i, (s, name)) in Self.notProse.enumerated() {
            let g = ProseDetector.signals(ProseMask.masked(s as NSString, language: .plain))
            #expect(!ProseDetector.isProse(s as NSString, language: .plain, fileName: name ?? "a.txt"),
                    "non-prose #\(i) detected as prose: \(g) \(s.prefix(40))")
        }
    }

    /// From the build 7 test pass: meeting notes with "Date:" and
    /// "Status:" lines are prose; a request log with key=value fields and
    /// trailing spaces is not, by content as well as by name.
    @Test func buildSevenDocuments() {
        let notes = """
        Meeting notes - Project Falcon
        Date: 18 Nov 2026
        Attendees: Ana, Ben, Chris, Dee

        Agenda
        1. Status update
        2. Budget
        3. Next steps

        Status: backend is 80% done, frontend behind by a week. Ben said the the API docs are out of date.
        Budget: on track, need sign off from finance for the new licences.

        Action items
        - Ana: update API docs by Friday
        - Ben: chase finance re licences
        - Chris: book demo room
        - Dee: send recap email

        """
        // Sniffed as Plain Text, not YAML (which turned off spelling and the owl's prose help).
        #expect(LanguageDetector.sniff(notes) == .plain, "\(LanguageDetector.sniff(notes))")
        #expect(LanguageDetector.sniff("name: cedric\nversion: 1.2\nenabled: true\npaths:\n  - /usr/bin\n") == .yaml)
        #expect(ProseDetector.isProse(notes as NSString, language: .plain, fileName: "meeting-notes.txt"),
                "\(ProseDetector.signals(ProseMask.masked(notes as NSString, language: .plain)))")
        let diary = "18 November\n\nWoke up late agian. Went to the shops and bought bread, forgot the milk ofcourse. Met Jenny for coffee, she told me about her new job, shes really excited about it.\n\nDidnt get much writing done today, I keep getting distracted by my phone. Tomorrow I will definately start earlier.  Maybe I'll go for a walk first.\n\ni think i need to sleep earlier to.\n"
        #expect(ProseDetector.isProse(diary as NSString, language: .plain, fileName: "diary.txt"))
        let log = (0..<20).map { "2026-11-18T10:00:\(String(format: "%02d", $0))Z INFO request id=\($0) path=/api/items status=200 dur=\($0)ms   " }
            .joined(separator: "\n") + "\n"
        for name in ["server.log", "server.txt", "untitled"] {
            #expect(!ProseDetector.isProse(log as NSString, language: .plain, fileName: name), "\(name)")
        }
        let kv = "user=anna role=admin last_login=2026-11-17 status=active\nuser=tom role=editor last_login=2026-11-02 status=away\nuser=sam role=viewer last_login=2026-10-30 status=active\n"
        #expect(!ProseDetector.isProse(kv as NSString, language: .plain))
    }

    @Test func onlyPlainTextAndMarkdown() {
        let s = Self.prose[0] as NSString
        for l in Language.allCases where l != .plain && l != .markdown {
            #expect(!ProseDetector.isProse(s, language: l), "\(l)")
        }
        #expect(ProseDetector.isProse(s, language: .plain))
        #expect(!ProseDetector.isProse(s, language: .plain, fileName: "app.log"))
    }

    @Test func markdownMaskBlanksCodeAndKeepsOffsets() {
        let s = "---\ntitle: x\n---\nSome `code` and a [link](https://x.com/a) here.\n```\nlet a = 1\n```\n| a | b |\n|---|---|\nEnd **now**.\n" as NSString
        let m = ProseMask.masked(s, language: .markdown) as NSString
        #expect(m.length == s.length)
        #expect(!(m as String).contains("title"))
        #expect(!(m as String).contains("code"))
        #expect(!(m as String).contains("https"))
        #expect((m as String).contains("link"))
        #expect(!(m as String).contains("let a"))
        #expect(!(m as String).contains("| a"))
        #expect((m as String).contains("End   now  ."))
        #expect((m as String).filter { $0 == "\n" }.count == (s as String).filter { $0 == "\n" }.count)
        let ranges = ProseMask.proseRanges(s, language: .markdown)
        let some = s.range(of: "Some")
        #expect(ranges.contains { NSLocationInRange(some.location, $0) })
        let code = s.range(of: "code")
        #expect(!ranges.contains { NSLocationInRange(code.location, $0) })
    }

    @Test func markdownSliceStartingInFenceOrFrontMatter() {
        // A slice of a long document that starts inside fenced code: the
        // open fence is passed in, so the code is blanked up to its close.
        let slice = "let the the = 1\nfoo()\n```\nThe the sentence after.\n" as NSString
        let m = ProseMask.masked(slice, language: .markdown, openFence: "```")
        #expect(!m.contains("let") && !m.contains("foo"))
        #expect(m.contains("The the sentence after."))
        // Without it the code would read as prose (what the fix is for).
        #expect(ProseMask.masked(slice, language: .markdown).contains("let the the"))
        // A longer fence isn't closed by a shorter run.
        let four = "code\n```\nstill code\n````\nProse.\n" as NSString
        let m4 = ProseMask.masked(four, language: .markdown, openFence: "````")
        #expect(!m4.contains("still") && m4.contains("Prose."))
        // Front matter: the slice's first units still in it are blanked.
        let doc = "---\ntitle: the the\nlayout: post\n---\nBody text here.\n" as NSString
        let end = ProseMask.frontMatterEnd(doc)
        #expect(end == doc.range(of: "Body").location)
        let start = doc.range(of: "layout").location
        let part = doc.substring(from: start) as NSString
        let mp = ProseMask.masked(part, language: .markdown, blankPrefix: end! - start)
        #expect(!mp.contains("layout") && !mp.contains("---") && mp.contains("Body text here."))
        #expect(ProseMask.frontMatterEnd("No front matter\n---\n" as NSString) == nil)
        #expect(ProseMask.frontMatterEnd("---\nnever closed\n" as NSString) == nil)
    }

    @Test func fenceIndexOpenFenceAtLineStart() {
        let text = "intro\n````swift\nlet a = 1\n```\nstill\n````\nafter\n~~~\nx\n" as NSString
        let index = LineIndex(text)
        let f = FenceIndex()
        #expect(f.openFence(text, index: index, line: 0) == nil)
        #expect(f.openFence(text, index: index, line: 1) == nil) // the opener itself
        #expect(f.openFence(text, index: index, line: 2) == "````")
        #expect(f.openFence(text, index: index, line: 4) == "````") // ``` doesn't close ````
        #expect(f.openFence(text, index: index, line: 6) == nil)
        #expect(f.openFence(text, index: index, line: 8) == "~~~")
    }

    @Test func plainTextMasksURLsOnly() {
        let s = "See www.example.com or mail me@example.com about it.\n" as NSString
        let m = ProseMask.masked(s, language: .plain)
        #expect(!m.contains("example"))
        #expect(m.hasPrefix("See ") && m.contains(" about it."))
    }

    /// Bounded: only the sample (`sampleLimit` units) is read, checked by
    /// what it decides, so this holds on any machine: a big file that opens
    /// with prose and goes on as code reads as prose, and the other way
    /// round as code. A detector that looked at the whole file gets both
    /// wrong. Fast: a time bound only against a blow-up in handling the
    /// sample. It was 1 s for 10 runs, and GitHub's macOS runners, busy
    /// with the rest of the suite, took 1.10 s and 1.42 s (release run
    /// 45208720302) for what takes 0.10 s on an M-series Mac; looking at
    /// the whole file took 3.5 s there. 10 s leaves the runners 7x.
    @Test(.offPool) func detectionIsBoundedAndFast() {
        let code = Self.notProse.first { $0.0.hasPrefix("#include") }!.0
        func repeated(_ s: String, toAtLeast n: Int) -> String { String(repeating: s, count: n / s.utf16.count + 1) }
        let proseHead = repeated(Self.prose[0], toAtLeast: ProseDetector.sampleLimit)
        let codeHead = repeated(code, toAtLeast: ProseDetector.sampleLimit)
        // A tail 40 times the sample: what a whole-file read would go by.
        let proseThenCode = (proseHead + repeated(code, toAtLeast: 350_000)) as NSString
        let codeThenProse = (codeHead + repeated(Self.prose[0], toAtLeast: 350_000)) as NSString
        #expect(ProseDetector.isProse(proseThenCode, language: .plain), "only the sample is read: the code after it isn't")
        #expect(!ProseDetector.isProse(codeThenProse, language: .plain), "only the sample is read: the prose after it isn't")

        let big = String(repeating: Self.prose[0], count: 2_000) as NSString // ~360 K
        let t0 = Date()
        for _ in 0..<10 { _ = ProseDetector.isProse(big, language: .plain) }
        let took = Date().timeIntervalSince(t0)
        print("prose-detection-timing 10 runs \(took) s")
        #expect(took < 10, "10 detections on a big file: \(took) s")
    }

    /// A time inside a sentence, or a leading clock time with no log marker,
    /// stays prose. A real syslog or app line (timestamp and a marker) does not.
    @Test func timestampsInsideProseStayProse() {
        let diary = """
        We landed at 2024-06-12 14:30:00 after a long delay on the tarmac.
        By 2024-06-12 16:05:00 we had walked to the hotel and checked in.
        """
        let workout = """
        0:00:00 Start with a light jog around the park near home.
        0:10:00 Stretch your legs and drink some water slowly.
        0:15:00 Begin the main set of intervals on the track.
        """
        for sample in [diary, workout] {
            let masked = ProseMask.masked(sample as NSString, language: .plain)
            #expect(!ProseDetector.signals(masked).readsAsLog, "\(ProseDetector.signals(masked))")
            #expect(ProseDetector.isProse(sample as NSString, language: .plain, fileName: "notes.txt"),
                    "\(ProseDetector.signals(masked))")
        }
        #expect(!ProseDetector.looksLikeLog("We landed at 2024-06-12 14:30:00 after a long delay on the tarmac."))
        #expect(!ProseDetector.looksLikeLog("0:00:00 Start with a light jog around the park near home."))
        // A level word with no leading timestamp is not a log line.
        #expect(!ProseDetector.looksLikeLog("app | INFO | The server was very slow today and we were really unhappy."))
        let syslog = """
        Nov 18 10:42:01 host sshd[1234]: Accepted publickey for droid from 10.0.0.5 port 50422
        Nov 18 10:42:03 host sshd[1234]: pam_unix(sshd:session): session opened for user droid
        """
        let iso = """
        2026-11-18 10:42:01 INFO Server started on port 8080
        2026-11-18 10:42:02 WARN Cache is cold
        """
        let bracketed = """
        [08:14:01] ERROR The cache was cold
        [08:14:02] INFO Retrying in 5 seconds
        """
        for sample in [syslog, iso, bracketed] {
            #expect(ProseDetector.signals(sample).readsAsLog, "\(ProseDetector.signals(sample))")
            #expect(!ProseDetector.isProse(sample as NSString, language: .plain, fileName: "events.txt"))
        }
    }

    /// Apple's unified log (Title Case level, fractional seconds, numeric
    /// offset) and syslog NOTICE / CRIT lines are logs. A dated note whose
    /// only colon is "Meeting notes:" or "Action items:" stays prose.
    @Test func unifiedLogAndSyslogLevelsAreLogsDatedNotesStayProse() {
        let unified = "2024-11-20 08:14:01.123456-0700 0x8a3d1 Error 0x0 481 0 Cedric: (Owlink) opened the notes"
        #expect(ProseDetector.looksLikeLog(unified))
        #expect(ProseDetector.looksLikeLog("2024-11-20 08:14:01.123456-0700 0x1 Default 0x0 1 0 Cedric: idle"))
        #expect(ProseDetector.looksLikeLog("2024-11-20 08:14:01.123456+0000 0x1 Fault 0x0 1 0 Cedric: trap"))
        #expect(ProseDetector.looksLikeLog("2024-11-20 08:14:01.123456-0700 0x1 Info 0x0 1 0 Cedric: ready"))
        let notice = "Nov 20 08:14:01 host NOTICE disk almost full and the queue stopped"
        let crit = "Nov 20 08:14:02 host CRIT shutting down after the disk filled"
        #expect(ProseDetector.looksLikeLog(notice))
        #expect(ProseDetector.looksLikeLog(crit))
        #expect(ProseDetector.signals(notice + "\n" + crit).readsAsLog)

        let notes = "2026-11-18 10:42:01 Meeting notes: kickoff"
        let actions = "Action items: send agenda"
        #expect(!ProseDetector.looksLikeLog(notes))
        #expect(!ProseDetector.looksLikeLog(actions))
        // A title-case name, or a bare `app:`, is not a process tag. Syslog still wants host then process.
        #expect(!ProseDetector.looksLikeLog("2024-11-20 08:14:01.123456-0700 0x1 Cedric: opened the notes"))
        #expect(!ProseDetector.looksLikeLog("2026-11-18 10:42:01 app: the server started"))
        #expect(ProseDetector.looksLikeLog("Nov 20 08:14:01 host app: the server started"))
        #expect(ProseDetector.looksLikeLog("Nov 20 08:14:01 host sshd[1234]: accepted a key"))
        let page = """
        \(notes)
        \(actions) to the whole team before Friday, and bring the draft.
        We met for an hour and agreed on the plan for the next release.
        The notes from today will go out with the agenda in the morning.
        """
        let g = ProseDetector.signals(page)
        #expect(!g.readsAsLog, "\(g)")
        #expect(ProseDetector.isProse(page as NSString, language: .plain, fileName: "notes.txt"), "\(g)")
    }

    @Test func codeLineShapes() {
        for l in ["let x = 5", "}", "foo(bar);", "2026-11-18 10:00 started", "[ERROR] boom", "key_name: value", "port: 8080",
                  "a,b,c,d", "x\ty\tz", "<div>", "// note"] {
            #expect(ProseDetector.looksLikeCode(l), "\(l)")
        }
        for l in ["Hi Sam,", "Let me know if you can make it.", "If you see this, call me.", "Note: the meeting is at noon, not ten.",
                  "We bought apples, pears, and two kinds of bread for the party."] {
            #expect(!ProseDetector.looksLikeCode(l), "\(l)")
        }
    }
}
