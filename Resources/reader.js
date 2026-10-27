// Splits the chapter into sentences and highlights the one being read, plus its current word.
(() => {
  const BLOCK = /^(P|DIV|H[1-6]|LI|BLOCKQUOTE|PRE|TD|TH|DT|DD|SECTION|ARTICLE|ASIDE|HEADER|FOOTER|FIGCAPTION|TR|TABLE|UL|OL|DL|BODY)$/i;
  const SKIP = 'script,style,head,rt,rp,noscript,nav';
  const MAX = 350;

  function blockOf(node) {
    let el = node.parentElement;
    while (el && !BLOCK.test(el.localName)) el = el.parentElement;
    return el;
  }

  // Flatten the text: one entry per text node, with "\n\n" between blocks so paragraphs never
  // merge. Then split it into sentences, cutting very long ones at a comma or similar.
  function segment(doc) {
    const nodes = [];
    let flat = '';
    let lastBlock = null;
    const walker = doc.createTreeWalker(doc.body || doc.documentElement, NodeFilter.SHOW_TEXT, {
      acceptNode: n => (n.parentElement && !n.parentElement.closest(SKIP)) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    });
    for (let n; (n = walker.nextNode());) {
      const block = blockOf(n);
      if (block !== lastBlock) {
        if (flat) flat += '\n\n';
        lastBlock = block;
      }
      nodes.push({ node: n, start: flat.length });
      // Line breaks inside the source markup are just spaces; keep the length so offsets still line up.
      flat += n.data.replace(/\s/g, ' ');
    }

    const root = doc.documentElement;
    const lang = root.getAttribute('lang') || root.getAttribute('xml:lang') || 'en';
    const sentences = [];
    for (const s of new Intl.Segmenter(lang, { granularity: 'sentence' }).segment(flat)) {
      let a = s.index, b = a + s.segment.length;
      while (a < b && /\s/.test(flat[a])) a++;
      while (b > a && /\s/.test(flat[b - 1])) b--;
      while (b - a > MAX) {
        const piece = flat.slice(a, a + MAX);
        let cut = -1;
        for (const mark of [',', ';', ':', '—', ' ']) {
          const i = piece.lastIndexOf(mark);
          if (i > MAX / 3) { cut = i + 1; break; }
        }
        if (cut < 0) cut = MAX;
        sentences.push([a, a + cut]);
        a += cut;
        while (a < b && /\s/.test(flat[a])) a++;
      }
      if (b > a && /[\p{L}\p{N}]/u.test(flat.slice(a, b))) sentences.push([a, b]);
    }
    return { nodes, flat, sentences };
  }

  const { nodes, flat, sentences } = segment(document);

  function locate(offset, isEnd) {
    const key = isEnd ? offset - 1 : offset;
    let lo = 0, hi = nodes.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (nodes[mid].start <= key) lo = mid; else hi = mid - 1;
    }
    const n = nodes[lo];
    return [n.node, Math.max(0, Math.min(offset - n.start, n.node.length))];
  }

  function rangeOf(a, b) {
    const r = document.createRange();
    r.setStart(...locate(a, false));
    r.setEnd(...locate(b, true));
    return r;
  }

  // Highlights are painted as boxes in a layer behind the text. (WebKit's CSS
  // highlight API sometimes left stale paint behind after scrolling.)
  const XHTML = 'http://www.w3.org/1999/xhtml';
  const body = document.body || document.documentElement;
  const layer = document.createElementNS(XHTML, 'div');
  layer.id = 'em-layer';
  body.insertBefore(layer, body.firstChild);

  function lineBoxes(range) {
    const rects = [...range.getClientRects()].filter(r => r.width > 0.5 && r.height > 0.5)
      .sort((a, b) => a.top - b.top || a.left - b.left);
    const lines = [];
    for (const r of rects) {
      const last = lines[lines.length - 1];
      if (last && Math.abs(r.top - last.top) < r.height / 2 && r.left <= last.right + 2) {
        last.right = Math.max(last.right, r.right);
        last.top = Math.min(last.top, r.top);
        last.bottom = Math.max(last.bottom, r.bottom);
      } else {
        lines.push({ left: r.left, right: r.right, top: r.top, bottom: r.bottom });
      }
    }
    return lines;
  }

  function paint(kind, range) {
    for (const old of [...layer.children]) if (old.dataset.kind === kind) old.remove();
    if (!range) return;
    const origin = layer.getBoundingClientRect();
    for (const b of lineBoxes(range)) {
      const box = document.createElementNS(XHTML, 'div');
      box.dataset.kind = kind;
      box.className = 'em-' + kind;
      box.style.left = (b.left - origin.left - 2) + 'px';
      box.style.top = (b.top - origin.top - 1) + 'px';
      box.style.width = (b.right - b.left + 4) + 'px';
      box.style.height = (b.bottom - b.top + 2) + 'px';
      layer.appendChild(box);
    }
  }

  function reveal(range) {
    const rect = range.getBoundingClientRect();
    const margin = innerHeight * 0.18;
    if (rect.top < margin || rect.bottom > innerHeight - margin) {
      scrollBy({ top: rect.top - innerHeight * 0.33, behavior: 'smooth' });
    }
  }

  let current = -1;
  let word = null;
  function repaint() {
    const s = sentences[current];
    paint('sentence', s ? rangeOf(s[0], s[1]) : null);
    paint('word', word ? rangeOf(word[0], word[1]) : null);
  }
  addEventListener('resize', repaint);
  addEventListener('load', repaint);

  window.earmark = {
    highlight(index, wordStart, wordLength, follow = true) {
      const s = sentences[index];
      if (!s) return;
      if (index !== current) {
        current = index;
        word = null;
        const r = rangeOf(s[0], s[1]);
        paint('sentence', r);
        paint('word', null);
        if (follow) reveal(r);
      }
      if (wordLength > 0) {
        word = [s[0] + wordStart, Math.min(s[0] + wordStart + wordLength, s[1])];
        const r = rangeOf(word[0], word[1]);
        paint('word', r);
        if (follow) reveal(r);
      }
    },
    // Index of the last anchor (by id) that comes before the current sentence, or -1.
    section(ids) {
      const s = sentences[Math.max(current, 0)];
      if (!s) return -1;
      const here = rangeOf(s[0], s[1]);
      let found = -1;
      ids.forEach((id, i) => {
        const el = document.getElementById(id);
        if (el && here.comparePoint(el, 0) <= 0) found = i;
      });
      return found;
    },
    // First sentence at or after the anchor with this id.
    sentenceAfter(id) {
      const el = document.getElementById(id);
      if (!el) return 0;
      const index = sentences.findIndex(s => rangeOf(s[0], s[1]).comparePoint(el, 0) <= 0
        || rangeOf(s[0], s[1]).intersectsNode(el));
      return Math.max(index, 0);
    },
    // What is highlighted now, as text (used by the debug log).
    state() {
      const s = sentences[current];
      return (s ? flat.slice(s[0], s[1]) : '') + ' || ' + (word ? flat.slice(word[0], word[1]) : '');
    },
    // The first sentences of another chapter's markup, split exactly as if it were open.
    firstSentences(markup, count) {
      let doc = new DOMParser().parseFromString(markup, 'application/xhtml+xml');
      if (doc.getElementsByTagName('parsererror').length) doc = new DOMParser().parseFromString(markup, 'text/html');
      const seg = segment(doc);
      return seg.sentences.slice(0, count).map(([a, b]) => seg.flat.slice(a, b));
    },
    clear() {
      current = -1;
      word = null;
      repaint();
    },
  };

  // Clicking a sentence starts reading from it.
  document.addEventListener('click', e => {
    if (e.target.closest('a') || String(getSelection())) return;
    const caret = document.caretRangeFromPoint(e.clientX, e.clientY);
    const entry = caret && nodes.find(x => x.node === caret.startContainer);
    if (!entry) return;
    const offset = entry.start + caret.startOffset;
    const index = sentences.findIndex(s => offset < s[1]);
    if (index >= 0) window.webkit.messageHandlers.earmark.postMessage({ type: 'seek', index });
  });

  window.webkit.messageHandlers.earmark.postMessage({
    type: 'ready',
    sentences: sentences.map(([a, b]) => flat.slice(a, b)),
  });
})();
