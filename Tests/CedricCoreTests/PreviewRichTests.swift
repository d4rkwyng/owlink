import Foundation
import Testing
@testable import CedricCore

/// The preview's options with math on (Allow JavaScript) or off.
private func render(_ s: String, math: Bool) -> String {
    var o = Markdown.Options.preview(vault: nil)
    o.math = math
    return Markdown.render(s, options: o).replacingOccurrences(of: #" data-line="\d+""#, with: "", options: .regularExpression)
}

private func m(_ s: String) -> String { render(s, math: true) }

/// A document with every construct the feature touches, and none.
let richCorpus = """
# Prices $5 and $10

Costs $5 and $10, or US$3. Escaped \\$x\\$ stays. Code `$a$` and `` $$b$$ `` too.

Inline $e^{i\\pi}+1=0$ and $x$5 here; $ spaced $ is not; $$ never closes.

$$
\\int_0^1 x\\,dx
$$

\\[ a^2 + b^2 = c^2 \\]

```mermaid
graph TD; A-->B
```

```
$not math$
```

    $indented code$

| a | b |
|---|---|
| $5 | *\\$4* |
"""

@Suite struct PreviewRichTests {
    // MARK: JS off: unchanged

    /// The golden render: what the preview drew before math existed (taken
    /// from the renderer at 70fadb2). Math off must keep drawing exactly this.
    static let golden = """
    <h1 id="prices-5-and-10">Prices $5 and $10</h1>
    <p>Costs $5 and $10, or US$3. Escaped \\$x\\$ stays. Code <code>$a$</code> and <code>$$b$$</code> too.</p>
    <p>Inline $e^{i\\pi}+1=0$ and $x$5 here; $ spaced $ is not; $$ never closes.</p>
    <p>$$
    \\int_0^1 x\\,dx
    $$</p>
    <p>[ a^2 + b^2 = c^2 ]</p>
    <pre><code class="language-mermaid">graph TD; A--&gt;B
    </code></pre>
    <pre><code>$not math$
    </code></pre>
    <pre><code>$indented code$
    </code></pre>
    <table>
    <thead>
    <tr><th>a</th><th>b</th></tr>
    </thead>
    <tbody>
    <tr><td>$5</td><td><em>\\$4</em></td></tr>
    </tbody>
    </table>

    """

    @Test func mathOffIsTheGoldenRender() {
        #expect(render(richCorpus, math: false) == Self.golden)
    }

    /// With math on, a document with no math renders byte for byte as with it off.
    @Test func mathOnWithoutMathIsUnchanged() {
        let plain = [
            "Costs $5 and $10.\n\nUS$3, $ 4 and \\$7.\n",
            "*\\$4* and **$5 or $6**\n",
            "`$a$` and\n\n```\n$$x$$\n```\n",
            "$HOME and $PATH are set\n",
            "",
            "# Plain\n\nNo dollars here, [a link](x.md) and \\[brackets\\].\n",
        ]
        for doc in plain {
            #expect(render(doc, math: true) == render(doc, math: false), "\(doc.debugDescription)")
            #expect(PreviewRich.needs(body: render(doc, math: true)).isEmpty, "\(doc.debugDescription)")
        }
    }

    // MARK: Detection

    @Test func inlineMath() {
        #expect(m("Euler: $e^{i\\pi}+1=0$.") == "<p>Euler: <span class=\"math math-inline\">e^{i\\pi}+1=0</span>.</p>\n")
        #expect(m("$a<b$") == "<p><span class=\"math math-inline\">a&lt;b</span></p>\n")
        // Emphasis characters inside math are TeX, not Markdown.
        #expect(m("$a_1 * b_2 * c$") == "<p><span class=\"math math-inline\">a_1 * b_2 * c</span></p>\n")
        #expect(m("$x$ and $y$") == "<p><span class=\"math math-inline\">x</span> and <span class=\"math math-inline\">y</span></p>\n")
        // Across a soft line break in one paragraph.
        #expect(m("$a +\nb$") == "<p><span class=\"math math-inline\">a +\nb</span></p>\n")
    }

    @Test func pricesAreNotMath() {
        #expect(m("$5 and $10") == "<p>$5 and $10</p>\n")
        #expect(m("It costs $5, or $10, or $15.") == "<p>It costs $5, or $10, or $15.</p>\n")
        #expect(m("from $5/$10 a month") == "<p>from $5/$10 a month</p>\n")
        // A closing `$` before a digit is no closer; one after a space neither.
        #expect(m("$x$5") == "<p>$x$5</p>\n")
        #expect(m("$ x $") == "<p>$ x $</p>\n")
        #expect(m("a $ b") == "<p>a $ b</p>\n")
    }

    @Test func escapedDollar() {
        // Literal in a document with math; as typed in one without.
        #expect(m("\\$5 and $x$") == "<p>$5 and <span class=\"math math-inline\">x</span></p>\n")
        #expect(m("\\$x\\$ and $y$") == "<p>$x$ and <span class=\"math math-inline\">y</span></p>\n")
        #expect(m("\\$x\\$") == "<p>\\$x\\$</p>\n")
        // An escaped dollar never opens or closes math.
        #expect(m("$a\\$ b$") == "<p><span class=\"math math-inline\">a\\$ b</span></p>\n")
    }

    @Test func codeIsNeverMath() {
        #expect(m("`$x$` and $y$") == "<p><code>$x$</code> and <span class=\"math math-inline\">y</span></p>\n")
        #expect(m("```\n$x$\n```") == "<pre><code>$x$\n</code></pre>\n")
        #expect(m("```tex\n$$\nx\n$$\n```").contains("math") == false)
        #expect(m("    $$x$$") == "<pre><code>$$x$$\n</code></pre>\n")
        // A price before a code span: the span stays code, no math across it.
        #expect(m("$5 and `$x$`") == "<p>$5 and <code>$x$</code></p>\n")
        #expect(m("Prices: $5 and $10. Code: `$x$`.") == "<p>Prices: $5 and $10. Code: <code>$x$</code>.</p>\n")
        #expect(m("x $$a `b` c$$") == "<p>x $$a <code>b</code> c$$</p>\n")
    }

    @Test func displayMath() {
        #expect(m("$$\nx^2\n$$") == "<div class=\"math math-display\">x^2</div>\n")
        #expect(m("$$x^2$$") == "<div class=\"math math-display\">x^2</div>\n")
        #expect(m("\\[\na \\le b\n\\]") == "<div class=\"math math-display\">a \\le b</div>\n")
        #expect(m("\\[ a \\]") == "<div class=\"math math-display\">a</div>\n")
        // In a paragraph: a display span.
        #expect(m("so $$x$$ here") == "<p>so <span class=\"math math-display\">x</span> here</p>\n")
        // Multi-line TeX keeps its lines; the block carries its source line.
        #expect(Markdown.render("p\n\n$$\na\\\\\nb\n$$", options: { var o = Markdown.Options.preview; o.math = true; return o }())
                == "<p data-line=\"0\">p</p>\n<div data-line=\"2\" class=\"math math-display\">a\\\\\nb</div>\n")
        // A blank line before the closer, or no closer: no block.
        #expect(m("$$\na\n\nb\n$$").contains("math-display") == false)
        #expect(m("$$\na") == "<p>$$\na</p>\n")
        // `\[` alone in prose is the CommonMark escape, as before.
        #expect(m("a \\[b\\] c") == "<p>a [b] c</p>\n")
    }

    @Test func mathInListsQuotesAndTables() {
        #expect(m("- $x$").contains("<span class=\"math math-inline\">x</span>"))
        #expect(m("> $$\n> y\n> $$").contains("<div class=\"math math-display\">y</div>"))
        #expect(m("| a |\n|---|\n| $z$ |").contains("<td><span class=\"math math-inline\">z</span></td>"))
    }

    @Test func manyDollarsStayLinear() {
        let line = String(repeating: "$a ", count: 20_000)
        let t0 = Date()
        let out = m(line)
        #expect(out.contains("math") == false)
        #expect(Date().timeIntervalSince(t0) < 5)
    }

    @Test func needs() {
        #expect(PreviewRich.needs(body: m(richCorpus)) == [.mermaid, .math])
        #expect(PreviewRich.needs(body: m("```mermaid\ngraph TD\n```")) == [.mermaid])
        #expect(PreviewRich.needs(body: m("```Mermaid\ngraph TD\n```")) == [.mermaid])
        #expect(PreviewRich.needs(body: m("$x$")) == [.math])
        #expect(PreviewRich.needs(body: m("\\[x\\]")) == [.math])
        // Math off: no math spans, so only the diagram.
        #expect(PreviewRich.needs(body: render(richCorpus, math: false)) == [.mermaid])
        // A mermaid word in prose or code isn't a diagram.
        #expect(PreviewRich.needs(body: m("`mermaid` and ```js\nmermaid\n```")).isEmpty)
    }

    // MARK: CSP

    /// The policies the preview has always used (PreviewController.csp at 70fadb2).
    @Test func cspWithoutNeedsIsUnchanged() {
        #expect(PreviewRich.csp(allowJavaScript: false, allowNetwork: false)
                == "default-src 'none'; img-src cedric-doc: file: data:; media-src cedric-doc: file: data:; style-src 'unsafe-inline' cedric-doc: file:; font-src cedric-doc: file: data:; script-src 'none'; connect-src 'none'")
        #expect(PreviewRich.csp(allowJavaScript: true, allowNetwork: false)
                == "default-src 'none'; img-src cedric-doc: file: data:; media-src cedric-doc: file: data:; style-src 'unsafe-inline' cedric-doc: file:; font-src cedric-doc: file: data:; script-src 'unsafe-inline' cedric-doc: file:; connect-src 'none'")
        #expect(PreviewRich.csp(allowJavaScript: false, allowNetwork: true)
                == "default-src 'none'; img-src cedric-doc: file: data: https: http:; media-src cedric-doc: file: data: https: http:; style-src 'unsafe-inline' cedric-doc: file: https: http:; font-src cedric-doc: file: data: https: http:; script-src 'none'; connect-src *")
        #expect(PreviewRich.csp(allowJavaScript: true, allowNetwork: true)
                == "default-src 'none'; img-src cedric-doc: file: data: https: http:; media-src cedric-doc: file: data: https: http:; style-src 'unsafe-inline' cedric-doc: file: https: http:; font-src cedric-doc: file: data: https: http:; script-src 'unsafe-inline' cedric-doc: file: https: http:; connect-src *")
    }

    @Test func cspWithNeedsAddsOnlyTheBundledFiles() {
        let both = PreviewRich.csp(allowJavaScript: true, allowNetwork: false, needs: [.mermaid, .math])
        #expect(both == "default-src 'none'; img-src cedric-doc: file: data:; media-src cedric-doc: file: data:; style-src 'unsafe-inline' cedric-doc: file: cedric-asset://vendor/katex/katex.min.css; font-src cedric-doc: file: data: cedric-asset://vendor/katex/fonts/; script-src 'unsafe-inline' cedric-doc: file: cedric-asset://vendor/katex/katex.min.js cedric-asset://vendor/mermaid/mermaid.min.js cedric-asset://vendor/owlink-rich.js; connect-src 'none'")
        let diagram = PreviewRich.csp(allowJavaScript: true, allowNetwork: false, needs: [.mermaid])
        #expect(diagram.contains("katex") == false)
        #expect(diagram.contains("script-src 'unsafe-inline' cedric-doc: file: cedric-asset://vendor/mermaid/mermaid.min.js cedric-asset://vendor/owlink-rich.js;"))
        // Never a whole scheme, never eval, never the network.
        for p in [both, diagram] {
            #expect(!p.contains("cedric-asset: ") && !p.contains("cedric-asset:;") && !p.contains("unsafe-eval"))
            #expect(p.hasSuffix("connect-src 'none'") && !p.contains("http"))
        }
        // JavaScript off: needs change nothing.
        #expect(PreviewRich.csp(allowJavaScript: false, allowNetwork: false, needs: [.mermaid, .math])
                == PreviewRich.csp(allowJavaScript: false, allowNetwork: false))
        // An export: only the bundled scripts, no page script.
        #expect(PreviewRich.csp(allowJavaScript: true, allowNetwork: false, needs: [.math], pageScripts: false)
                .contains("script-src cedric-asset://vendor/katex/katex.min.js cedric-asset://vendor/owlink-rich.js;"))
        #expect(PreviewRich.csp(allowJavaScript: true, allowNetwork: false, needs: [], pageScripts: false).contains("script-src 'none';"))
    }

    @Test func tags() {
        #expect(PreviewRich.headTags([]) == "" && PreviewRich.tailTags([], dark: true) == "")
        #expect(PreviewRich.headTags([.mermaid]) == "")
        #expect(PreviewRich.headTags([.math]) == "<link rel=\"stylesheet\" href=\"cedric-asset://vendor/katex/katex.min.css\">\n")
        #expect(PreviewRich.tailTags([.mermaid, .math], dark: true) == """
        <script src="cedric-asset://vendor/katex/katex.min.js"></script>
        <script src="cedric-asset://vendor/mermaid/mermaid.min.js"></script>
        <script src="cedric-asset://vendor/owlink-rich.js" data-dark="1"></script>

        """)
    }

    @Test func assetAllowList() {
        func path(_ s: String) -> String? { URL(string: s).flatMap(PreviewRich.assetPath(for:)) }
        #expect(path("cedric-asset://vendor/mermaid/mermaid.min.js") == "mermaid/mermaid.min.js")
        #expect(path("cedric-asset://vendor/katex/fonts/KaTeX_Main-Regular.woff2") == "katex/fonts/KaTeX_Main-Regular.woff2")
        #expect(path("cedric-asset://vendor/owlink-rich.js") == "owlink-rich.js")
        #expect(PreviewRich.files.count == 24)
        for bad in ["cedric-asset://vendor/../../Info.plist", "cedric-asset://vendor/katex/../mermaid/LICENSE",
                    "cedric-asset://vendor/katex/fonts/KaTeX_Main-Regular.ttf", "cedric-asset://other/owlink-rich.js",
                    "cedric-asset://vendor/owlink-rich.js?x=1", "cedric-doc://vendor/owlink-rich.js",
                    "cedric-asset://vendor/", "cedric-asset://vendor/mermaid/LICENSE", "https://vendor/owlink-rich.js",
                    "cedric-asset://vendor/%2e%2e/owlink-rich.js"] {
            #expect(path(bad) == nil, "\(bad)")
        }
    }
}
