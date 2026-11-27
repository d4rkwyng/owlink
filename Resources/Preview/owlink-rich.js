// Owlink's Markdown preview, Allow JavaScript on: draws the page's
// ```mermaid blocks (Mermaid) and math (KaTeX), both bundled in the app and
// loaded only for a document that has them (Sources/CedricCore/PreviewRich.swift).
// Each block keeps its element (and its data-line, for scrolling in step);
// a diagram that doesn't parse keeps its source and shows Mermaid's error
// above it. When everything is drawn, <html data-owlink-rich="done">.
(function () {
  'use strict';
  var me = document.currentScript;
  var dark = !!(me && me.dataset.dark === '1');
  var root = document.documentElement;
  var done = function () { root.setAttribute('data-owlink-rich', 'done'); };

  // Math: Markdown.Options.math's spans and blocks hold the escaped TeX.
  if (window.katex) {
    var maths = document.querySelectorAll('.math.math-inline, .math.math-display');
    for (var i = 0; i < maths.length; i++) {
      var el = maths[i];
      var tex = el.textContent;
      try {
        // throwOnError false: bad TeX is shown in red, with KaTeX's message as its title.
        window.katex.render(tex, el, { displayMode: el.classList.contains('math-display'), throwOnError: false, trust: false, output: 'htmlAndMathml' });
      } catch (e) {
        el.textContent = tex;
        el.title = String((e && e.message) || e);
        el.classList.add('math-error');
      }
    }
  }

  if (!window.mermaid) { done(); return; }
  var codes = Array.prototype.filter.call(document.querySelectorAll('pre > code'), function (c) {
    return c.className.toLowerCase() === 'language-mermaid';
  });
  if (!codes.length) { done(); return; }
  // strict: labels are text, no click handlers or links run from a diagram.
  window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
                              theme: dark ? 'dark' : 'default' });
  var n = 0;
  // One at a time, as Mermaid lays out in a shared scratch element.
  var next = function () {
    if (n >= codes.length) { done(); return; }
    var code = codes[n], pre = code.parentElement, id = 'owlink-mermaid-' + n;
    n += 1;
    var source = code.textContent;
    var tidy = function () {
      ['d' + id, id].forEach(function (x) { var t = document.getElementById(x); if (t && !pre.contains(t)) t.remove(); });
    };
    window.mermaid.render(id, source).then(function (r) {
      tidy();
      var box = document.createElement('div');
      box.className = 'mermaid-diagram';
      box.innerHTML = r.svg;
      pre.classList.add('mermaid-drawn');
      pre.style.background = 'none';
      pre.style.whiteSpace = 'normal';
      pre.style.textAlign = 'center';
      pre.style.overflowX = 'auto';
      code.style.display = 'none';
      pre.insertBefore(box, code);
    }, function (e) {
      tidy();
      var msg = document.createElement('div');
      msg.className = 'mermaid-error';
      msg.style.whiteSpace = 'pre-wrap';
      msg.style.color = '#e5534b';
      msg.style.marginBottom = '.5em';
      msg.textContent = 'Mermaid: ' + String((e && (e.message || e.str)) || e);
      pre.insertBefore(msg, code);
    }).then(next, next);
  };
  next();
})();
