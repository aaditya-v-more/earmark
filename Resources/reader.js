// Splits the chapter into sentences and highlights the one being read, plus its current word.
(() => {
  const BLOCK = /^(P|DIV|H[1-6]|LI|BLOCKQUOTE|PRE|TD|TH|DT|DD|SECTION|ARTICLE|ASIDE|HEADER|FOOTER|FIGCAPTION|TR|TABLE|UL|OL|DL|BODY)$/i;
  const SKIP = 'script,style,head,rt,rp,noscript';

  function blockOf(node) {
    let el = node.parentElement;
    while (el && !BLOCK.test(el.localName)) el = el.parentElement;
    return el;
  }

  // Flatten the text: one entry per text node, with "\n\n" between blocks so paragraphs never merge.
  const nodes = [];
  let flat = '';
  let lastBlock = null;
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT, {
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

  const lang = document.documentElement.getAttribute('lang') || document.documentElement.getAttribute('xml:lang') || 'en';
  const sentences = [];
  for (const s of new Intl.Segmenter(lang, { granularity: 'sentence' }).segment(flat)) {
    let a = s.index, b = a + s.segment.length;
    while (a < b && /\s/.test(flat[a])) a++;
    while (b > a && /\s/.test(flat[b - 1])) b--;
    if (b > a && /[\p{L}\p{N}]/u.test(flat.slice(a, b))) sentences.push([a, b]);
  }

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

  function reveal(range) {
    const rect = range.getBoundingClientRect();
    const margin = innerHeight * 0.18;
    if (rect.top < margin || rect.bottom > innerHeight - margin) {
      scrollBy({ top: rect.top - innerHeight * 0.33, behavior: 'smooth' });
    }
  }

  let current = -1;
  window.earmark = {
    highlight(index, wordStart, wordLength) {
      const s = sentences[index];
      if (!s) return;
      if (index !== current) {
        current = index;
        const r = rangeOf(s[0], s[1]);
        CSS.highlights.set('em-sentence', new Highlight(r));
        CSS.highlights.delete('em-word');
        reveal(r);
      }
      if (wordLength > 0) {
        const r = rangeOf(s[0] + wordStart, Math.min(s[0] + wordStart + wordLength, s[1]));
        CSS.highlights.set('em-word', new Highlight(r));
        reveal(r);
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
    clear() {
      current = -1;
      CSS.highlights.clear();
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
