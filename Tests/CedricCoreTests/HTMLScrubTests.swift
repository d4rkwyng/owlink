import Foundation
import Testing
@testable import CedricCore

/// Security audit L4 (export keeps scripts) and M3 (rich text remote loads).
@Suite struct HTMLScrubTests {
    @Test func exportHasNoScript() {
        let md = "# T\n\n<script>alert(1)</script>\n\n<img src=\"a.png\" onerror=\"alert(2)\">\n\n<iframe src=\"https://x\"></iframe>\n\n<a href=\"javascript:alert(3)\">j</a> <a href='https://example.com/ok'>ok</a>\n\n<div onclick=alert(4) ONMOUSEOVER='x'>d</div>\n"
        let html = HTMLScrub.noScript(Markdown.render(md, options: .preview))
        let low = html.lowercased()
        #expect(!low.contains("<script") && !low.contains("alert(1)"))
        #expect(!low.contains("onerror") && !low.contains("onclick") && !low.contains("onmouseover"))
        #expect(!low.contains("<iframe") && !low.contains("javascript:"))
        #expect(html.contains("src=\"a.png\"") && html.contains("https://example.com/ok"), "the rest is kept")
        #expect(html.contains("<h1"))
    }

    @Test func richTextHasNoRemoteLoads() {
        let html = "<link rel=stylesheet href='https://t/css'><style>@import url('https://t/i'); p{background:url(http://t/bg)}</style><p style=\"background:url('//t/x')\">p</p><img src=\"https://tracker.example/p.gif\"><img src=dot.png><img srcset=\"https://t/a 2x\"><a href=\"https://example.com\">link</a>"
        let s = HTMLScrub.noScriptNoRemote(html)
        #expect(!s.contains("https://t") && !s.contains("http://t") && !s.contains("//t/") && !s.contains("tracker"), "\(s)")
        #expect(s.contains("src=dot.png") && s.contains(">link</a>"))
    }

    /// The iOS preview: a link to the web stays a link (a tap the app
    /// decides); nothing else remote is kept.
    @Test func previewKeepsLinksButNoRemoteLoads() {
        let html = "<link rel=stylesheet href='https://t/css'><style>@import url('https://t/i'); p{background:url(http://t/bg)}</style><p style=\"background:url('//t/x')\">p</p><img src=\"https://tracker.example/p.gif\"><img src=dot.png><img srcset=\"https://t/a 2x\"><a href=\"https://example.com/ok\">link</a> <a title=\"t\" HREF='http://example.com/two'>two</a> <a/href=//example.com/three>three</a> <map><area shape=rect href=\"https://example.com/area\"></map><svg><a xlink:href=\"https://t/x\">s</a><image href=\"https://t/img\"/><use href=\"https://t/use\"/></svg><a href=\"https://example.com/ok\"><img src=\"https://t/badge\"></a><abbr href=\"https://t/abbr\">a</abbr><p>see href=\"https://example.com/text\"</p><a href=\"javascript:alert(1)\">j</a>"
        let s = HTMLScrub.noScriptNoRemoteKeepingLinks(html)
        #expect(!s.contains("https://t") && !s.contains("http://t") && !s.contains("//t/") && !s.contains("tracker"), "\(s)")
        #expect(s.contains("<a href=\"https://example.com/ok\">link</a>"), "\(s)")
        #expect(s.contains("HREF='http://example.com/two'") && s.contains("href=//example.com/three") && s.contains("href=\"https://example.com/area\""), "\(s)")
        #expect(s.contains("src=dot.png") && !s.lowercased().contains("alert(1)"))
        // The rich-text scrub is unchanged: no remote href there.
        #expect(!HTMLScrub.noScriptNoRemote(html).contains("example.com/ok"))

        // Review of fc73458 (Opus SF1): a stray quote makes the tag regex
        // read the next element as part of the `<a>`; its href still goes.
        let fooled = [
            #"<svg><a x=a"><image href="https://t.example/p.png" y=""></svg>"#,
            #"<svg><a x=a"><use href="https://t.example/u.svg#x" y=""></svg>"#,
            #"<a x=a'><img src=dot.png><image href='https://t.example/q.png' y=''>"#,
        ]
        for f in fooled {
            let out = HTMLScrub.noScriptNoRemoteKeepingLinks(f)
            #expect(!out.contains("t.example"), "\(f) -> \(out)")
        }
        // Fail safe: a `<` in an earlier attribute costs a real link its href.
        #expect(!HTMLScrub.noScriptNoRemoteKeepingLinks(#"<a title="<b>" href="https://example.com/ok">x</a>"#).contains("example.com"))
    }

    /// Review of fc73458 (Grok SF2, Opus SF4): a remote URL attribute after
    /// a `/` or a closing quote (no space) is one a browser loads too.
    @Test func remoteAttributesAfterEverySeparator() {
        let cases = [
            #"<img/src=https://t.example/p.gif>"#,
            #"<img/src="https://t.example/p.gif">"#,
            #"<img alt=""src=https://t.example/p.gif>"#,
            #"<img alt=''src='https://t.example/p.gif'>"#,
            #"<body/background=https://t.example/bg.png>"#,
            #"<svg><image/href=https://t.example/i.png /></svg>"#,
            #"<img alt="x"srcset="https://t.example/a 2x">"#,
            #"<video/poster=//t.example/v.png></video>"#,
        ]
        for html in cases {
            #expect(!HTMLScrub.noScriptNoRemote(html).contains("t.example"), "\(html) -> \(HTMLScrub.noScriptNoRemote(html))")
            #expect(!HTMLScrub.noScriptNoRemoteKeepingLinks(html).contains("t.example"), "\(html) -> \(HTMLScrub.noScriptNoRemoteKeepingLinks(html))")
        }
        // A link's own href written the same ways still stays in the preview.
        #expect(HTMLScrub.noScriptNoRemoteKeepingLinks(#"<a title="t"href="https://example.com/ok">x</a>"#).contains("https://example.com/ok"))
        #expect(HTMLScrub.noScriptNoRemoteKeepingLinks(#"<a/href=https://example.com/ok>x</a>"#).contains("https://example.com/ok"))
        // Local sources are left alone.
        #expect(HTMLScrub.noScriptNoRemote(#"<img/src=dot.png><img alt=""src="a.png">"#) == #"<img/src=dot.png><img alt=""src="a.png">"#)
    }

    /// Review of fc73458 (Grok SF4): a kept link's `rel` can't ask WebKit
    /// to fetch or resolve ahead of a tap; other keywords stay.
    @Test func previewLinksLoseFetchingRel() {
        let cases: [(String, String)] = [
            (#"<a rel="prefetch" href="https://example.com/a">a</a>"#, #"<a  href="https://example.com/a">a</a>"#),
            (#"<a href="https://example.com/a" rel="noopener PreConnect dns-prefetch nofollow">a</a>"#,
             #"<a href="https://example.com/a" rel="noopener nofollow">a</a>"#),
            (#"<a href="https://example.com/a" rel='preload modulepreload prerender'>a</a>"#, #"<a href="https://example.com/a" >a</a>"#),
            (#"<a/rel=prefetch href="https://example.com/a">a</a>"#, #"<a/ href="https://example.com/a">a</a>"#),
            (#"<area href="https://example.com/a" rel="pre&#102;etch">"#, #"<area href="https://example.com/a" >"#),
        ]
        for (html, want) in cases {
            #expect(HTMLScrub.noScriptNoRemoteKeepingLinks(html) == want, "\(html)")
        }
        let plain = #"<a href="https://example.com/a" rel="noopener noreferrer">a</a>"#
        #expect(HTMLScrub.noScriptNoRemoteKeepingLinks(plain) == plain)
    }

    /// Review of fc73458 (Grok MUST-FIX 1, Opus SF2): a kept link's `ping`
    /// would POST to its URLs on a tap, before the app decides the tap.
    /// Every scrub drops the whole attribute, however it is written.
    @Test func pingIsDroppedByEveryScrub() {
        let cases = [
            #"<a href="https://example.com/ok" ping="https://t.example/p1 https://t.example/p2">x</a>"#,
            #"<a href="https://example.com/ok" ping='https://t.example/p'>x</a>"#,
            #"<a href="https://example.com/ok" ping=https://t.example/p>x</a>"#,
            #"<a href="https://example.com/ok" PING = "https://t.example/p">x</a>"#,
            #"<a/ping=https://t.example/p href="https://example.com/ok">x</a>"#,
            #"<a href="https://example.com/ok"ping="https://t.example/p">x</a>"#,
            #"<a title='t'ping='https://t.example/p'href="https://example.com/ok">x</a>"#,
            #"<area shape=rect href="https://example.com/ok" ping="https://t.example/p">"#,
        ]
        for html in cases {
            for (name, s) in [("noScript", HTMLScrub.noScript(html)), ("noScriptNoRemote", HTMLScrub.noScriptNoRemote(html)),
                              ("keepingLinks", HTMLScrub.noScriptNoRemoteKeepingLinks(html))] {
                #expect(!s.lowercased().contains("ping") && !s.contains("t.example"), "\(name): \(html) -> \(s)")
            }
            #expect(HTMLScrub.noScriptNoRemoteKeepingLinks(html).contains("https://example.com/ok"), "the link itself stays: \(html)")
        }
        // Only the attribute named `ping`: others and the text are left alone.
        let kept = #"<a href="https://example.com/ok" data-ping="1" pinged="2">ping me</a>"#
        #expect(HTMLScrub.noScript(kept) == kept)
    }

    /// Review of fc73458 (Grok SF1, Opus SF3; older than that commit): a
    /// meta refresh hidden from the `refresh` regex. Every `<meta>` with an
    /// `http-equiv` other than a CSP goes, read as a browser reads it.
    @Test func metaHTTPEquivOtherThanCSPIsDropped() {
        let bad = [
            #"<meta http-equiv="&#114;efresh" content="0;url=other.html">"#,
            #"<meta http-equiv="&#x52;EFRESH" content="0;url=other.html">"#,
            #"<meta http-equiv=" refresh " content="0;url=other.html">"#,
            #"<meta content="0;url=other.html?a>b" http-equiv="refresh">"#,
            #"<meta x=a" y="z>" http-equiv=refresh content="0;url=other.html">"#,
            #"<meta/http-equiv=refresh content=0;url=other.html>"#,
            #"<META HTTP-EQUIV="Set-Cookie" content="a=b">"#,
            #"<meta http-equiv="content-security-policy&#x20;x" content="0;url=other.html">"#,
            #"<meta http-equiv content="0;url=other.html">"#,
        ]
        for html in bad {
            for (name, s) in [("noScript", HTMLScrub.noScript(html)), ("noScriptNoRemote", HTMLScrub.noScriptNoRemote(html)),
                              ("keepingLinks", HTMLScrub.noScriptNoRemoteKeepingLinks(html))] {
                #expect(!s.lowercased().contains("<meta"), "\(name): \(html) -> \(s)")
            }
        }
        // The rest of the document stays.
        #expect(HTMLScrub.noScript(#"<p>a</p><meta http-equiv="&#114;efresh" content="0;url=x.html"><p>b</p>"#) == "<p>a</p><p>b</p>")
        // A CSP (the rich-text copy scrubs a page that starts with the
        // app's own) and metas with no http-equiv are kept.
        let page = PreviewHTML.page(body: "<p>x</p>", palette: EditorPalettes.light, csp: MarkdownExport.csp)
        #expect(HTMLScrub.noScriptNoRemote(page).contains(#"<meta http-equiv="Content-Security-Policy" content="\#(MarkdownExport.csp)">"#))
        #expect(HTMLScrub.noScriptNoRemote(page).contains(#"<meta charset="utf-8">"#))
        let keep = #"<meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src 'none'">"#
        #expect(HTMLScrub.noScript(keep) == keep)
        #expect(HTMLScrub.noScript("<p>http-equiv=refresh</p>") == "<p>http-equiv=refresh</p>")
    }

    /// Release review 0.2.1 M1: script URLs a browser still runs although
    /// the plain text "javascript:" isn't there.
    @Test func scriptURLsInEveryForm() {
        let bad = [
            // `/` as the attribute separator
            #"<a/href="javascript:alert(1)">x</a>"#,
            #"<a/href=javascript:alert(1)>x</a>"#,
            #"<a title="t"href="javascript:alert(1)">x</a>"#,
            #"<img/src='vbscript:msgbox(1)'>"#,
            // character references: decimal, hex, no `;`, leading zeros, named
            #"<a href="&#106;avascript:alert(1)">x</a>"#,
            #"<a href="&#x6a;avascript:alert(1)">x</a>"#,
            #"<a href="&#X6A;&#x61;vascript:alert(1)">x</a>"#,
            #"<a href="&#106avascript:alert(1)">x</a>"#,
            #"<a href="&#0000106;avascript:alert(1)">x</a>"#,
            #"<a href="javascript&colon;alert(1)">x</a>"#,
            #"<a href="java&Tab;script:alert(1)">x</a>"#,
            #"<a href="java&NewLine;script:alert(1)">x</a>"#,
            #"<a href=&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1)>x</a>"#,
            // whitespace and control characters inside or before the scheme
            "<a href=\"java\tscript:alert(1)\">x</a>",
            "<a href=\"java\nscript:alert(1)\">x</a>",
            "<a href=\"java\rscript:alert(1)\">x</a>",
            "<a href=\"\u{01}javascript:alert(1)\">x</a>",
            "<a href=\"jav\u{0B}ascript:alert(1)\">x</a>",
            "<a href=\" \t javascript:alert(1)\">x</a>",
            "<a href=\"JaVa\tScRiPt:alert(1)\">x</a>",
            "<a href=\"vb&#x09;script:msgbox(1)\">x</a>",
            "<form action=\"&#x6A;avascript:alert(1)\"><button formaction='java&#9;script:alert(1)'>b</button></form>",
            "<svg><a xlink:href=\"java&#10;script:alert(1)\">x</a></svg>",
        ]
        for html in bad {
            let s = HTMLScrub.noScript(html)
            #expect(!s.lowercased().contains("alert(1)") && !s.lowercased().contains("msgbox(1)"), "\(html) -> \(s)")
            #expect(s.contains("\"#\""), "the link is kept, pointing nowhere: \(s)")
            #expect(HTMLScrub.noScriptNoRemote(html).contains("\"#\""))
            #expect(HTMLScrub.noScriptNoRemoteKeepingLinks(html).contains("\"#\""))
        }
        // Not script URLs: kept as written.
        let good = [
            #"<a href="https://example.com/javascript:x">x</a>"#,
            #"<a href="docs/javascript.html">x</a>"#,
            ##"<a href="#javascript:x">x</a>"##,
            #"<a href="a?b=1&amp;c=2">x</a>"#,
            #"<img src="data:image/png;base64,iVBORw0KGgo=">"#,
        ]
        for html in good { #expect(HTMLScrub.noScript(html) == html, "\(html)") }
        // Text outside tags is never rewritten.
        let text = "<p>type javascript:alert(1) or href=&#106;avascript:</p>"
        #expect(HTMLScrub.noScript(text) == text)
    }

    @Test func characterReferences() {
        #expect(HTMLScrub.decodeCharacterReferences("&#106;&#x61;&#X76;&#97&colon;&Tab;&amp;&unknown;&#99999999999;") == "java:\t&&unknown;\u{FFFD}")
    }
}
