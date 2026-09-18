/* Post-processing for rendered summaries.
 *
 * `marked` turns the summary into correct but flat HTML. What makes a
 * summary pleasant to read is its *shape*: numbered sections that group
 * their own body text, labelled sub-points, weighted topic lists, a
 * takeaway pulled out of the flow. None of that is expressible in the
 * Markdown the model emits, and most of it isn't expressible in CSS
 * either — a section is a group of siblings, not an element.
 *
 * So this file rebuilds the shape after parsing. Every step is defensive:
 * if anything here fails the worst case is the plain `marked` output,
 * which is what the app showed before, so it wraps everything in a
 * try/catch rather than risking a blank page.
 *
 * Kept out of MarkdownView.swift on purpose — as a Swift string literal
 * every regex escape here would need doubling. */

(function () {
  'use strict';

  function enhance(root) {
    flattenLooseItems(root);
    groupIntoCards(root);
    numberHeadings(root);
    decorateWeightTags(root);
    decorateLeadParagraphs(root);
    decorateLabels(root);
    decorateTasks(root);
    wrapTables(root);
    markCJK(root);
  }

  /* ---- 0. Unwrap "loose" list items ---------------------------------
   * A blank line anywhere in a list makes `marked` wrap every item's text
   * in a <p>, which (a) adds paragraph margins that make a tight list look
   * ragged and (b) puts a <strong> one level deeper than the styling and
   * the label pass expect. The summaries alternate between the two forms
   * for no semantic reason, so normalise on the tight one. */
  function flattenLooseItems(root) {
    root.querySelectorAll('li').forEach(function (li) {
      var paragraphs = Array.prototype.filter.call(li.children, function (child) {
        return child.tagName === 'P';
      });
      if (paragraphs.length !== 1) return;
      var p = paragraphs[0];
      if (p.previousElementSibling) return; // only when the text leads the item

      var fragment = document.createDocumentFragment();
      while (p.firstChild) fragment.appendChild(p.firstChild);
      fragment.appendChild(document.createTextNode(' '));
      li.replaceChild(fragment, p);
    });
  }

  /* ---- 1. Group each heading with the body text it owns --------------
   * A "section" is an <h2>/<h3> plus every following sibling up to the
   * next heading of the same level. Turning that into a real element is
   * what lets the card styling exist at all. */
  function groupIntoCards(root) {
    var probe = pickSectionLevel(root);
    if (!probe) return;

    var tag = 'H' + probe;
    var children = Array.prototype.slice.call(root.children);
    var current = null;

    children.forEach(function (el) {
      if (el.tagName === tag) {
        current = document.createElement('section');
        current.className = 'card';
        root.insertBefore(current, el);
        current.appendChild(el);
      } else if (current) {
        current.appendChild(el);
      }
      // Anything before the first heading — normally the <h1> title —
      // stays where it is.
    });
  }

  /* Which heading level actually delimits the sections?
   *
   * Not simply the shallowest. A summary typically reads
   *   ## Meeting Summary
   *   ### 1. Core Conclusions
   * so carding on `h2` would put the entire document inside one card.
   * Take the shallowest level that has at least two members; a level with
   * a single heading is a title, not a section break. */
  function pickSectionLevel(root) {
    for (var level = 2; level <= 4; level++) {
      if (root.querySelectorAll('h' + level).length >= 2) return level;
    }
    return 0;
  }

  /* ---- 2. "### 2. Key Discussion Topics" -> numbered badge --------------------- */
  function numberHeadings(root) {
    root.querySelectorAll('h2, h3, h4').forEach(function (h) {
      var match = h.textContent.match(/^\s*(\d{1,2})\s*[.、)．]\s*(.+)$/);
      if (!match) return;
      h.textContent = '';
      var badge = document.createElement('span');
      badge.className = 'num';
      badge.textContent = match[1];
      h.appendChild(badge);
      h.appendChild(document.createTextNode(match[2]));
    });
  }

  /* ---- 3. "[30%]" -> inline weight chip ----------------------------- */
  function decorateWeightTags(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);

    nodes.forEach(function (node) {
      var value = node.nodeValue || '';
      if (!/\[\s*\d{1,3}\s*%\]/.test(value)) return;

      var fragment = document.createDocumentFragment();
      var regex = /\[\s*(\d{1,3})\s*%\]/g;
      var last = 0;
      var match;
      while ((match = regex.exec(value)) !== null) {
        fragment.appendChild(document.createTextNode(value.slice(last, match.index)));
        var chip = document.createElement('span');
        chip.className = 'pct';
        chip.textContent = match[1] + '%';
        fragment.appendChild(chip);
        last = match.index + match[0].length;
      }
      fragment.appendChild(document.createTextNode(value.slice(last)));
      node.parentNode.replaceChild(fragment, node);
    });
  }

  /* ---- 4. "▲ …" -> highlighted takeaway ----------------------------- */
  function decorateLeadParagraphs(root) {
    root.querySelectorAll('p').forEach(function (p) {
      if (!/^\s*\u25B2/.test(p.textContent || '')) return;
      p.classList.add('lead');
      var first = p.firstChild;
      if (first && first.nodeType === 3) {
        first.nodeValue = first.nodeValue.replace(/^\s*\u25B2\s*/, '');
      }
    });
  }

  /* ---- 5. "**Discussion Focus**:" -> pill, and drop the now-stranded colon -- */
  function decorateLabels(root) {
    root.querySelectorAll('li > strong').forEach(function (strong) {
      var next = strong.nextSibling;
      if (!next || next.nodeType !== 3) return;
      next.nodeValue = next.nodeValue.replace(/^[\s:：]+/, ' ');
    });
  }

  /* ---- 6. "- [ ] Copy | Owner: | Time:" ----------------------------
   * The action-items format packs several labelled fields into one line.
   * Split them so each field can be a chip instead of a run-on. */
  function decorateTasks(root) {
    root.querySelectorAll('li').forEach(function (li) {
      var box = li.querySelector(':scope > input[type="checkbox"]')
        || li.querySelector(':scope > p > input[type="checkbox"]');
      if (!box) return;
      li.classList.add('task');

      var text = '';
      var scrap = [];
      Array.prototype.forEach.call(li.childNodes, function (node) {
        if (node === box) return;
        if (node.nodeType === 3) {
          text += node.nodeValue;
          scrap.push(node);
        } else if (node.nodeName === 'P' || node.nodeName === 'SPAN') {
          text += node.textContent;
          scrap.push(node);
        }
      });

      var trimmed = text.replace(/\s+/g, ' ').trim();
      if (!trimmed) return;

      scrap.forEach(function (node) { node.parentNode.removeChild(node); });

      var body = document.createElement('span');
      body.className = 'task-body';

      var parts = trimmed.split(/\uFF5C|\|/).map(function (s) { return s.trim(); })
        .filter(function (s) { return s.length > 0; });

      var title = document.createElement('span');
      title.textContent = parts[0];
      body.appendChild(title);

      parts.slice(1).forEach(function (part) {
        var chip = document.createElement('span');
        chip.className = 'meta';
        var colon = part.search(/[：:]/);
        if (colon > 0) {
          var label = document.createElement('b');
          label.textContent = part.slice(0, colon);
          chip.appendChild(label);
          var value = part.slice(colon + 1).trim();
          if (value) chip.appendChild(document.createTextNode(value));
        } else {
          chip.textContent = part;
        }
        body.appendChild(chip);
      });

      li.appendChild(body);
    });
  }

  /* ---- 7. Tables scroll instead of overflowing the page -------------- */
  function wrapTables(root) {
    root.querySelectorAll('table').forEach(function (table) {
      var parent = table.parentElement;
      if (!parent || parent.classList.contains('table-wrap')) return;
      var wrap = document.createElement('div');
      wrap.className = 'table-wrap';
      parent.insertBefore(wrap, table);
      wrap.appendChild(table);
    });
  }

  /* ---- 8. CJK gets looser leading ------------------------------------ */
  function markCJK(root) {
    var text = root.textContent || '';
    if (!text) return;
    var matches = text.match(/[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]/g);
    var ratio = (matches ? matches.length : 0) / text.length;
    if (ratio > 0.12) document.body.classList.add('cjk');
  }

  window.__nomilyEnhanceSummary = function () {
    try {
      var root = document.getElementById('content');
      if (root) enhance(root);
    } catch (error) {
      // Deliberately swallowed: plain marked output is a fine fallback and
      // a thrown error here would leave the reader with nothing.
    }
  };
})();
