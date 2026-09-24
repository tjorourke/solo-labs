/* wizard.js — the question flow.
 *
 * Holds one plan object, re-renders the current step from it, and asks vsr-core.js to
 * turn it into a config on every change. No framework: the whole thing is one state
 * object, a render function per step, and event delegation.
 *
 * It mounts into whatever element has id="vw", so tools/vsr-workbench can serve the
 * same three files and get the same wizard with a live router behind it. When a host
 * sets window.VSR_HOST = {validate, name}, the review step offers to send the config to
 * the running router's own validator as well.
 */
(function () {
  'use strict';

  var VSR = window.VSR;
  var STORE = 'vsr-wizard-plan-v1';

  // Where the self-hostable copy lives: the same files plus a Dockerfile, an nginx
  // config, Kubernetes manifests and a README.
  var REPO = 'https://github.com/tjorourke/solo-labs/tree/main/vsr-config-builder';

  var STEPS = [
    { id: 'start', label: 'Start' },
    { id: 'categories', label: 'Categories' },
    { id: 'signals', label: 'Signals' },
    { id: 'confusions', label: 'Comparisons' },
    { id: 'order', label: 'Order' },
    { id: 'review', label: 'Review' }
  ];

  var state = {
    step: 0,
    plan: null,
    touched: {}
  };

  // Placeholders carry "e.g." on purpose. Without it an example reads as a value
  // that is already filled in, which is exactly how the old hardcoded "Looking at
  // existing code" managed to appear under a category called "sensitive".
  var NAME_EG = [
    'e.g. never_leaves',
    'e.g. eu_only',
    'e.g. anywhere',
    'e.g. customer_support'
  ];
  var DESC_EG = [
    'e.g. anything that must not leave our own datacentre',
    'e.g. anything with a named person in it',
    'e.g. nothing confidential, any approved model can answer',
    'e.g. a question that came from a customer'
  ];

  /* ------------------------------------------------------------------- dom -- */
  function el(tag, attrs, kids) {
    var n = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === null || v === undefined || v === false) return;
        if (k === 'class') n.className = v;
        else if (k === 'text') n.textContent = v;
        else if (k === 'html') n.innerHTML = v;
        else if (k.slice(0, 2) === 'on') n.addEventListener(k.slice(2), v);
        else n.setAttribute(k, v === true ? '' : v);
      });
    }
    (kids || []).forEach(function (k) {
      if (k === null || k === undefined || k === false) return;
      n.appendChild(typeof k === 'string' ? document.createTextNode(k) : k);
    });
    return n;
  }

  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }

  function lines(s) {
    return String(s || '').split('\n')
      .map(function (x) { return x.trim(); })
      .filter(Boolean);
  }

  function commaList(s) {
    return String(s || '').split(',')
      .map(function (x) { return x.trim(); })
      .filter(Boolean);
  }

  /* ----------------------------------------------------------------- state -- */
  function save() {
    try { localStorage.setItem(STORE, JSON.stringify(state.plan)); } catch (e) { /* private mode */ }
  }

  function load() {
    try {
      var raw = localStorage.getItem(STORE);
      if (raw) return JSON.parse(raw);
    } catch (e) { /* ignore */ }
    return null;
  }

  function loadPreset(key) {
    var p = window.VSR_PRESETS[key];
    state.plan = JSON.parse(JSON.stringify(p.plan));
    // Remembered so the review step can offer the real file this was modelled on,
    // and survives a reload because it is saved with the plan.
    state.plan.fromPreset = key;
    save();
  }

  function planExample() {
    var p = window.VSR_PRESETS[state.plan && state.plan.fromPreset];
    return p && p.example ? p.example : null;
  }

  function cats() { return state.plan.categories; }

  function pairOn(a, b) {
    return state.plan.pairs.some(function (p) { return p.a === a && p.b === b; }) ||
      state.plan.pairs.some(function (p) { return p.a === b && p.b === a; });
  }

  function togglePair(a, b) {
    var i = -1;
    state.plan.pairs.forEach(function (p, idx) {
      if ((p.a === a && p.b === b) || (p.a === b && p.b === a)) i = idx;
    });
    if (i >= 0) state.plan.pairs.splice(i, 1);
    else state.plan.pairs.push({ a: a, b: b });
    save();
  }

  /* --------------------------------------------------------------- stepper -- */
  function tick() {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('aria-hidden', 'true');
    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M5 12.5l4.5 4.5L19 7.5');
    path.setAttribute('stroke', 'currentColor');
    path.setAttribute('stroke-width', '2.6');
    path.setAttribute('stroke-linecap', 'round');
    path.setAttribute('stroke-linejoin', 'round');
    svg.appendChild(path);
    return svg;
  }

  function renderSteps() {
    var nav = document.getElementById('vw-steps');
    clear(nav);
    nav.style.setProperty('--steps', String(STEPS.length));
    STEPS.forEach(function (s, i) {
      var done = i < state.step;
      var node = el('span', { class: 'n' });
      if (done) node.appendChild(tick());
      else node.appendChild(document.createTextNode(String(i + 1)));
      nav.appendChild(el('button', {
        type: 'button',
        class: 'step' + (done ? ' done' : ''),
        'aria-current': i === state.step ? 'step' : null,
        'aria-label': 'Step ' + (i + 1) + ' of ' + STEPS.length + ': ' + s.label,
        onclick: function () { go(i); }
      }, [node, el('span', { class: 'lbl', text: s.label })]));
    });

    // The same thing for narrow screens, where six labels on one line stop being
    // readable well before they stop fitting.
    var compact = document.getElementById('vw-steps-compact');
    clear(compact);
    var pct = ((state.step + 1) / STEPS.length) * 100;
    compact.appendChild(el('div', { class: 'sc-row' }, [
      el('span', { class: 'sc-now', text: STEPS[state.step].label }),
      el('span', { class: 'sc-of', text: 'Step ' + (state.step + 1) + ' of ' + STEPS.length })
    ]));
    compact.appendChild(el('div', { class: 'sc-track' }, [
      el('div', { class: 'sc-fill', style: 'width:' + pct + '%' })
    ]));
  }

  function go(i) {
    state.step = Math.max(0, Math.min(STEPS.length - 1, i));
    render();
    var top = document.getElementById('vw');
    if (top && state.step > 0) top.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function navRow(backLabel, nextLabel) {
    return el('div', { class: 'navrow' }, [
      state.step > 0
        ? el('button', { class: 'btn', type: 'button', onclick: function () { go(state.step - 1); } },
          ['\u2190 ' + (backLabel || STEPS[state.step - 1].label)])
        : el('span'),
      state.step < STEPS.length - 1
        ? el('button', { class: 'btn primary', type: 'button', onclick: function () { go(state.step + 1); } },
          [(nextLabel || STEPS[state.step + 1].label) + ' \u2192'])
        : el('span')
    ]);
  }

  /* ---------------------------------------------------------------- step 0 -- */
  function stepStart(body) {
    body.appendChild(el('div', { class: 'panel' }, [
      el('h3', { text: 'What this does' }),
      el('p', { class: 'lede' }, [
        'Five questions about the kinds of request you want to tell apart, and it writes ' +
        'the router\'s values file for you. Then it checks the file for the mistake that ' +
        'is hardest to spot by eye: a rule that looks fine and can never actually fire.'
      ]),
      el('p', { class: 'lede' }, [
        'Nothing leaves the browser, and your answers are saved here so a reload does ' +
        'not lose them. Pick a starting point below, or ',
        el('a', { href: REPO, target: '_blank', rel: 'noopener' },
          ['run it yourself from the repo']),
        ': it is a static page, so self-hosting it is an nginx image and five files.'
      ]),
      why('The two ideas the questions are built on', [
        'A config is a set of <b>signals</b> and a set of <b>decisions</b>.',
        'A signal is something the router can measure about a prompt: its subject, ' +
        'whether it contains certain words, and how close it sounds to one set of ' +
        'example prompts rather than another.',
        'A decision is a list of signals that must all hold, a priority, and the label ' +
        'to write when they do.',
        'The YAML is never the hard part. Choosing which signals separate your ' +
        'categories, and what order to try them in, is the hard part, and that is what ' +
        'these questions are for.'
      ])
    ]));

    var picks = el('div', { class: 'panel' }, [
      el('h3', { text: 'Start from' })
    ]);
    Object.keys(window.VSR_PRESETS).forEach(function (key) {
      var p = window.VSR_PRESETS[key];
      var reveal = el('div');
      picks.appendChild(el('div', { class: 'cat' }, [
        el('div', { class: 'row spread' }, [
          el('div', { class: 'grow' }, [
            el('div', { style: 'font-weight:700;font-size:14.5px' }, [p.title]),
            el('p', { class: 'hint', style: 'margin:5px 0 0;max-width:70ch' }, [p.blurb])
          ]),
          el('div', { class: 'row' }, [
            p.example ? el('button', {
              class: 'btn', type: 'button',
              onclick: function (e) { toggleExample(p.example, reveal, e.target); }
            }, ['Show the lab\'s config']) : null,
            el('button', {
              class: 'btn primary', type: 'button',
              onclick: function () { loadPreset(key); go(1); }
            }, ['Use this'])
          ])
        ]),
        reveal
      ]));
    });
    body.appendChild(picks);

    if (load()) {
      body.appendChild(el('div', { class: 'panel' }, [
        el('div', { class: 'row spread' }, [
          el('div', { class: 'grow' }, [
            el('div', { style: 'font-weight:700;font-size:14.5px' }, ['Carry on where you left off']),
            el('p', { class: 'hint', style: 'margin:5px 0 0' },
              ['There is a plan saved in this browser.'])
          ]),
          el('div', { class: 'row' }, [
            el('button', {
              class: 'btn danger', type: 'button',
              onclick: function () {
                try { localStorage.removeItem(STORE); } catch (e) { /* ignore */ }
                render();
              }
            }, ['Discard it']),
            el('button', {
              class: 'btn primary', type: 'button',
              onclick: function () { state.plan = load(); go(1); }
            }, ['Resume'])
          ])
        ])
      ]));
    }
  }

  /* --------------------------------------------------------------- example --
   * The lab's real config, fetched from the lab rather than copied into this page,
   * so the worked example cannot drift from the file the lab deploys and tests.
   *
   * Same-origin on the published site. Inside tools/vsr-workbench the page is served
   * from localhost, where the relative path is not there and the absolute one is
   * cross-origin with no CORS header, so both paths fail and we show a link instead.
   * That is the right answer there anyway: the workbench already has the file open.
   */
  var exampleCache = {};

  function fetchExample(ex) {
    if (exampleCache[ex.url]) return Promise.resolve(exampleCache[ex.url]);

    var get = function (url) {
      return fetch(url).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text();
      }).then(function (text) {
        // A static host that falls back to index.html on a miss answers 200 with
        // its own markup. Check this is actually the config before believing it.
        if (!/(^|\n)\s*config:/.test(text) || /<html/i.test(text)) {
          throw new Error('not a router config');
        }
        return text;
      });
    };

    // On the published site the relative path is right and costs nothing. Anywhere
    // else, a self-hosted container for instance, it is certain to miss, so go
    // straight to the absolute URL rather than logging a 404 on the way past. The
    // lab file is served with access-control-allow-origin: *, so that works.
    var onSite = location.pathname.indexOf('/solo/') === 0;
    var first = onSite ? ex.url : ex.absolute;
    var second = onSite ? ex.absolute : ex.url;

    return get(first)
      .catch(function () { return get(second); })
      .then(function (text) {
        exampleCache[ex.url] = text;
        return text;
      });
  }

  function toggleExample(ex, mount, btn) {
    if (mount.firstChild) {
      clear(mount);
      btn.textContent = 'Show the lab\'s config';
      return;
    }
    btn.textContent = 'Hide the lab\'s config';
    clear(mount);
    mount.appendChild(el('p', { class: 'hint', style: 'margin:14px 0 0' },
      ['fetching ' + ex.name + '\u2026']));

    fetchExample(ex).then(function (text) {
      clear(mount);
      mount.appendChild(exampleBody(ex, text));
    }).catch(function () {
      clear(mount);
      mount.appendChild(el('div', { style: 'margin:14px 0 0' }, [
        el('p', { class: 'hint', style: 'margin:0 0 8px' }, [
          'The file is on the published site and this page cannot reach it from here. ' +
          'Open it directly:'
        ]),
        el('a', { class: 'btn', href: ex.absolute, target: '_blank', rel: 'noopener' },
          [ex.name + ' \u2197'])
      ]));
    });
  }

  function exampleBody(ex, text) {
    var wrap = el('div', { style: 'margin:14px 0 0' });
    wrap.appendChild(el('div', { class: 'row spread', style: 'margin-bottom:10px' }, [
      el('div', {}, [
        el('div', { style: 'font-weight:700;font-size:13.5px' }, [ex.name]),
        el('div', { class: 'hint' },
          [text.split('\n').length + ' lines, as deployed by the lab'])
      ]),
      el('div', { class: 'row' }, [
        el('button', {
          class: 'btn tiny', type: 'button',
          onclick: function (e) { copy(text, e.target); }
        }, ['Copy']),
        el('a', { class: 'btn tiny', href: ex.lab }, ['Open the lab'])
      ])
    ]));
    wrap.appendChild(el('pre', { class: 'yaml', text: text }));
    return wrap;
  }

  function differencesPanel(ex) {
    var list = el('ul', { style: 'margin:0;padding-left:20px' });
    (ex.differences || []).forEach(function (d) {
      list.appendChild(el('li', { html: d, style: 'margin:0 0 9px;line-height:1.6' }));
    });
    var reveal = el('div');
    return el('div', { class: 'panel' }, [
      el('h3', { text: 'How this compares with the lab\'s own file' }),
      el('p', {
        class: 'lede',
        html: 'The preset is the Part 4 lab expressed as answers, so what you get here is ' +
          'the same six labels and the same signals. It is not the same file byte for ' +
          'byte, and the differences are worth knowing before you diff the two:'
      }),
      list,
      el('div', { class: 'row', style: 'margin-top:14px' }, [
        el('button', {
          class: 'btn', type: 'button',
          onclick: function (e) { toggleExample(ex, reveal, e.target); }
        }, ['Show the lab\'s config'])
      ]),
      reveal
    ]);
  }

  /* ---------------------------------------------------------------- step 1 -- */
  function stepCategories(body) {
    body.appendChild(el('div', { class: 'panel' }, [
      el('h3', { text: 'What kinds of request do you want to tell apart?' }),
      el('p', { class: 'lede' },
        ['Give each one a short name. The router picks exactly one for every prompt.']),
      why('What these names are, and what they are not', [
        'They are not model names. They are the router\'s answer to "what kind of ' +
        'prompt is this", written into the request\'s <code>model</code> field.',
        'What happens next, which model answers and where it runs, is decided after ' +
        'the router by your route and your policy. Keeping these as task names rather ' +
        'than model names is what lets you swap the model behind a category later ' +
        'without touching the router at all.'
      ]),
      catList(),
      el('div', { class: 'row', style: 'margin-top:12px' }, [
        el('button', {
          class: 'btn', type: 'button', onclick: function () {
            cats().push({ name: '', description: '', domains: [], keywords: [], phrases: [] });
            save(); render();
          }
        }, ['Add another'])
      ])
    ]));

    body.appendChild(el('div', { class: 'panel' }, [
      el('h3', { text: 'What if it is none of them?' }),
      el('p', { class: 'lede' },
        ['Every config needs an answer for a prompt that matches nothing. Pick a name ' +
          'for it and send it somewhere safe.']),
      why('Why this one matters more than it looks', [
        'This is <code>default_model</code>. It means a prompt the router does not ' +
        'understand gets a label you chose, rather than whichever category happened to ' +
        'come closest.',
        'It gets a model card and a provider entry of its own, but no decision, because ' +
        'it is what the router falls through to rather than something it matches.'
      ]),
      el('label', { class: 'field', style: 'max-width:420px' }, [
        el('span', { class: 'lbl' }, ['Name for "not sure"']),
        el('input', {
          type: 'text', value: state.plan.fallback, placeholder: 'uncertain',
          oninput: function (e) { state.plan.fallback = e.target.value; save(); }
        })
      ]),

      // A field with a default that is right for every lab on this site. Folded away
      // rather than removed: someone not fronting the router with agentgateway does
      // need to change it.
      el('details', { class: 'adv' }, [
        el('summary', { text: 'Advanced: the address each label points at' }),
        el('div', { class: 'adv-body' }, [
          el('label', { class: 'field' }, [
            el('span', { class: 'lbl' }, ['Backend endpoint']),
            el('input', {
              type: 'text', value: state.plan.endpoint,
              oninput: function (e) { state.plan.endpoint = e.target.value; save(); }
            }),
            el('div', { class: 'hint', style: 'margin-top:5px' }, [
              'Set this to your agentgateway Service. The config will not validate ' +
              'without an address here, but the router does not send traffic to it: it ' +
              'reads the prompt, says which label it is, and agentgateway forwards the ' +
              'request. The router is a classifier on this path, not a proxy.'
            ]),
            el('div', { class: 'hint', style: 'margin-top:5px' }, [
              'Every lab on this site has that Service running, so "the router does not ' +
              'connect to it" has not been tested with the Service missing. Point it at ' +
              'the real one rather than relying on it being ignored.'
            ])
          ])
        ])
      ])
    ]));

    body.appendChild(navRow(null, 'Signals'));
  }

  /* A collapsible block of teaching prose. Closed by default: the step should be
   * usable without reading it, and still explain itself to anyone who wants that. */
  function why(summary, paras) {
    var bodyEl = el('div', { class: 'why-body' });
    paras.forEach(function (p) { bodyEl.appendChild(el('p', { html: p })); });
    return el('details', { class: 'why' }, [
      el('summary', { text: summary }),
      bodyEl
    ]);
  }

  function catList() {
    var wrap = el('div');
    cats().forEach(function (c, i) {
      wrap.appendChild(el('div', { class: 'cat' }, [
        el('div', { class: 'cat-head' }, [
          el('span', { class: 'ord', text: String(i + 1) }),
          el('span', { class: 'grow' }),
          el('button', {
            class: 'btn tiny', type: 'button', title: 'Move up', disabled: i === 0,
            onclick: function () { swap(i, i - 1); }
          }, ['\u2191']),
          el('button', {
            class: 'btn tiny', type: 'button', title: 'Move down', disabled: i === cats().length - 1,
            onclick: function () { swap(i, i + 1); }
          }, ['\u2193']),
          el('button', {
            class: 'btn tiny danger', type: 'button',
            onclick: function () { removeCat(i); }
          }, ['Remove'])
        ]),
        el('div', { class: 'cat-grid' }, [
          el('label', { class: 'field' }, [
            el('span', { class: 'lbl' }, ['Name']),
            el('input', {
              type: 'text', value: c.name, placeholder: NAME_EG[i % NAME_EG.length],
              oninput: function (e) { renameCat(i, e.target.value); }
            }),
            // Only worth saying when the config will not use what they typed.
            (c.name && VSR.slug(c.name) !== c.name)
              ? el('div', { class: 'hint', style: 'margin-top:5px' },
                ['Written as ', el('code', { text: VSR.slug(c.name) }), ' in the config.'])
              : null
          ]),
          el('label', { class: 'field' }, [
            el('span', { class: 'lbl' }, ['A note to yourself (optional)']),
            el('input', {
              type: 'text', value: c.description || '',
              placeholder: DESC_EG[i % DESC_EG.length],
              oninput: function (e) { c.description = e.target.value; save(); }
            })
          ])
        ])
      ]));
    });
    return wrap;
  }

  function swap(i, j) {
    var a = cats();
    var t = a[i]; a[i] = a[j]; a[j] = t;
    save(); render();
  }

  function removeCat(i) {
    var gone = VSR.slug(cats()[i].name);
    cats().splice(i, 1);
    state.plan.pairs = state.plan.pairs.filter(function (p) {
      return VSR.slug(p.a) !== gone && (p.b === VSR.REST || VSR.slug(p.b) !== gone);
    });
    save(); render();
  }

  function renameCat(i, value) {
    var old = cats()[i].name;
    cats()[i].name = value;
    state.plan.pairs.forEach(function (p) {
      if (p.a === old) p.a = value;
      if (p.b === old) p.b = value;
    });
    save();
  }

  /* ---------------------------------------------------------------- step 2 -- */
  function stepSignals(body) {
    body.appendChild(el('div', { class: 'panel' }, [
      el('h3', { text: 'How would you recognise each one?' }),
      el('p', { class: 'lede' }, [
        'Three ways to spot a category. Fill in whichever ones you can, and skip the ' +
        'rest: nothing here is compulsory.'
      ]),
      why('Which of the three to reach for', [
        '<b>Subject</b> is a fixed classifier with fourteen labels. It is reliable on ' +
        'what a prompt is about, and says nothing about what it asks for.',
        '<b>Words</b> catch the short, blunt asks that are too brief for anything else ' +
        'to work on.',
        '<b>Phrasings</b> are example prompts. The router scores how much closer a ' +
        'prompt sits to one category\'s examples than another\'s, and it is the only ' +
        'one of the three that can tell "review this function" from "change this ' +
        'function", because those two are the same subject and share most of their ' +
        'words.',
        'A category that is purely a subject needs only the subject. A category the ' +
        'classifier has no label for, your own product line, say, needs example prompts, ' +
        'because that is the only way to define it at all.'
      ])
    ]));

    cats().forEach(function (c, i) {
      body.appendChild(signalPanel(c, i));
    });
    body.appendChild(navRow(null, 'Comparisons'));
  }

  function signalPanel(c, i) {
    var domainChips = el('div', { class: 'chips' });
    VSR.DOMAINS.forEach(function (d) {
      var on = (c.domains || []).indexOf(d.name) >= 0;
      domainChips.appendChild(el('button', {
        type: 'button', class: 'chip', 'aria-pressed': on ? 'true' : 'false',
        title: d.description,
        onclick: function () {
          c.domains = c.domains || [];
          var k = c.domains.indexOf(d.name);
          if (k >= 0) c.domains.splice(k, 1); else c.domains.push(d.name);
          save(); render();
        }
      }, [d.name]));
    });

    var phraseCount = (c.phrases || []).length;
    var bankWarn = phraseCount > 0 && phraseCount < 3;
    var noSignals = !(c.domains || []).length && !(c.keywords || []).length && !phraseCount;

    return el('div', { class: 'panel' }, [
      el('div', { class: 'cat-head' }, [
        el('span', { class: 'ord', text: String(i + 1) }),
        el('span', { class: 'nm', text: VSR.slug(c.name || 'unnamed') }),
        c.description ? el('span', { class: 'hint' }, ['\u00b7 ' + c.description]) : null
      ]),

      // Every field below is optional on its own. All three empty is not, because then
      // there is nothing for the router to match, and the category can never be picked.
      noSignals
        ? el('div', { class: 'verdict meh', style: 'margin:0 0 16px' }, [
          el('b', {}, ['Nothing to match on yet. ']),
          'Fill in at least one of the three below, or this category can never be ' +
          'chosen. Use the examples if you want a starting point.'
        ])
        : null,

      snippetPicker(c),

      el('div', { class: 'field' }, [
        el('span', { class: 'lbl' },
          ['Subject (optional) \u00b7 the only fourteen this can return']),
        domainChips,
        el('div', { class: 'hint', style: 'margin-top:7px' }, [
          el('b', {}, ['Nothing here fits? Leave them all off. ']),
          'That is normal, and it is not a gap you have to work around: define the ' +
          'category with example prompts below instead. That is how the lab identifies telco, ' +
          'and how a data class like "must stay in the EU" gets identified, because ' +
          'neither of those is a subject.'
        ]),
        why('Why you cannot add a fifteenth', [
          'This list is not configuration. It is the output of a fine-tuned classifier ' +
          'head shipped with the router, and the fourteen names live in ' +
          '<code>category_mapping.json</code> on its volume. They are the subject ' +
          'categories of MMLU-Pro, the benchmark it was trained on.',
          'Adding a fifteenth name to the <code>domains</code> block has no effect. The ' +
          'head can only ever return one of the fourteen, so a decision waiting on your ' +
          'new name would never fire. A question about a 5G handover comes back as ' +
          'computer science, engineering or business depending on how it was worded.',
          'So a category the list has no word for is built the other way round: a ' +
          'list of words plus a comparison. In the lab, telco is a list of network terms ' +
          'and six network questions, and it works well enough to outrank ' +
          'everything else.'
        ])
      ]),

      el('label', { class: 'field' }, [
        el('span', { class: 'lbl' }, ['Words that give it away (optional)']),
        el('input', {
          type: 'text', value: (c.keywords || []).join(', '),
          placeholder: 'e.g. strictly confidential, proprietary, internal only',
          oninput: function (e) { c.keywords = commaList(e.target.value); save(); }
        }),
        el('div', { class: 'hint', style: 'margin-top:5px' },
          ['Comma separated. Scored with bm25, which stems, so ', el('code', { text: 'change' }),
            ' fires on "changes" and ', el('code', { text: 'look over' }),
            ' fires on "have a look at this". Multi-word terms are not matched as phrases.'])
      ]),

      el('label', { class: 'field' }, [
        el('span', { class: 'lbl' },
          ['Example prompts (optional) \u00b7 one per line']),
        el('textarea', {
          rows: Math.max(4, Math.min(10, phraseCount + 2)),
          placeholder: 'e.g. Summarise how our pricing model works for the new tier\n' +
            'e.g. What does this internal incident report say about the root cause\n' +
            'e.g. Check this board paper before it goes to the meeting',
          oninput: function (e) { c.phrases = lines(e.target.value); save(); }
        }, [(c.phrases || []).join('\n')]),
        el('div', { class: 'hint', style: 'margin-top:5px' }, [
          'These are the definition of the signal, not test data. Hold your test prompts ' +
          'out of here: a prompt that is also listed here scores against itself and proves ' +
          'nothing.'
        ]),
        bankWarn ? el('div', { class: 'hint', style: 'margin-top:5px;color:var(--w-warn)' },
          ['Only ' + phraseCount + ' so far. The score takes the closest one, so with ' +
            'two or three, a single odd entry decides the whole thing. Six is a good number.'])
          : null
      ])
    ]);
  }

  /* Ready-made signals, dropped into a category. Adds to whatever is already there
   * rather than replacing it, so picking the wrong one costs an undo and not your
   * work, and skips anything already present so picking twice is harmless. */
  function snippetPicker(c) {
    var sel = el('select', {
      onchange: function (e) {
        var pick = findSnippet(e.target.value);
        e.target.selectedIndex = 0;
        if (!pick) return;
        c.keywords = merge(c.keywords, pick.keywords);
        c.phrases = merge(c.phrases, pick.phrases);
        save(); render();
      }
    }, [el('option', { value: '', text: 'Insert an example\u2026' })]);

    (window.VSR_SNIPPETS || []).forEach(function (g) {
      var grp = el('optgroup', { label: g.group });
      g.items.forEach(function (it) {
        grp.appendChild(el('option', { value: g.group + ' :: ' + it.label, text: it.label }));
      });
      sel.appendChild(grp);
    });

    return el('div', { class: 'row', style: 'margin:0 0 16px' }, [
      el('div', { style: 'max-width:320px;flex:0 1 320px' }, [sel]),
      el('span', { class: 'hint', style: 'flex:1 1 220px' }, [
        'Fills in the words and the example prompts below. Edit them afterwards: the ones ' +
        'that work are the ones that sound like your own people.'
      ])
    ]);
  }

  function findSnippet(value) {
    var parts = String(value || '').split(' :: ');
    var out = null;
    (window.VSR_SNIPPETS || []).forEach(function (g) {
      if (g.group !== parts[0]) return;
      g.items.forEach(function (it) { if (it.label === parts[1]) out = it; });
    });
    return out;
  }

  function merge(existing, incoming) {
    var out = (existing || []).slice();
    (incoming || []).forEach(function (v) { if (out.indexOf(v) < 0) out.push(v); });
    return out;
  }

  /* ---------------------------------------------------------------- step 3 -- */
  function stepConfusions(body) {
    var withPhrases = cats().filter(function (c) { return (c.phrases || []).length; });

    // Comparing every pair is nearly always what you want, so start with them all on
    // rather than with a blank slate. Done once, and remembered, so unticking one does
    // not get undone on the next render.
    if (!state.plan.pairsInitialised && withPhrases.length > 1) {
      state.plan.pairsInitialised = true;
      if (!(state.plan.pairs || []).length) {
        for (var a = 0; a < withPhrases.length; a++) {
          for (var b = a + 1; b < withPhrases.length; b++) {
            state.plan.pairs.push({ a: withPhrases[a].name, b: withPhrases[b].name });
          }
        }
      }
      save();
    }

    body.appendChild(el('div', { class: 'panel' }, [
      el('h3', { text: 'Which categories could be confused with each other?' }),
      el('p', { class: 'lede' }, [
        'The router can only ever compare two categories at a time, so each box below ' +
        'sets up one comparison. They start ticked, because comparing them all is ' +
        'usually right. Untick any pair that could never be mistaken for one another.'
      ]),
      why('Why it asks about pairs, when you already gave each category its examples', [
        'Because there is no "whichever category is closest wins" setting. That is the ' +
        'thing most people expect, and the router does not work that way.',
        'A comparison scores <b>one category minus another</b>: how close the prompt ' +
        'sits to the first category\'s examples, minus how close it sits to the ' +
        'second\'s. One number, from exactly two sets of examples. So "is this A or B" ' +
        'is a question that has to be asked explicitly, once per pair.',
        'That is also why you do not need a comparison for every combination. If two ' +
        'categories could never be mistaken for each other, the comparison costs you a ' +
        'rule and buys you nothing.',
        'One thing to watch: keep both sides of a comparison on the same subject where ' +
        'you can. If they differ in subject as well as in what they ask for, the rule ' +
        'learns the subject, and then it fires on anything about that subject whatever ' +
        'the prompt actually asks for.'
      ])
    ]));

    if (withPhrases.length < 2) {
      body.appendChild(notEnoughPrompts(withPhrases.length));
      if (withPhrases.length < 1) {
        body.appendChild(navRow(null, 'Order'));
        return;
      }
    }

    var live = countPairs();
    var pairPanel = el('div', { class: 'panel' }, [
      el('div', { class: 'row spread', style: 'margin-bottom:4px' }, [
        el('h3', { style: 'margin:0' }, ['One against one']),
        el('span', { class: 'hint' },
          [live + ' comparison' + (live === 1 ? '' : 's') + ' will be created'])
      ]),
      el('p', { class: 'hint', style: 'margin:6px 0 14px' },
        ['Only categories that have example prompts can appear here.'])
    ]);

    for (var i = 0; i < withPhrases.length; i++) {
      for (var j = i + 1; j < withPhrases.length; j++) {
        pairPanel.appendChild(pairRow(withPhrases[i], withPhrases[j]));
      }
    }
    body.appendChild(pairPanel);

    var restPanel = el('div', { class: 'panel' }, [
      el('h3', { text: 'One against all the others' }),
      el('p', { class: 'lede' }, [
        'Use this when a category has no single obvious rival and just needs to stand ' +
        'apart from everything else you handle. It compares that category against every ' +
        'other category\'s examples rolled into one.'
      ]),
      why('When this is the right shape, and when it is not', [
        'This is the answer for a category the subject list has no word for, where the ' +
        'thing that defines it is the subject itself rather than what the prompt asks ' +
        'for. The lab uses exactly this for telco.',
        'It is the one comparison whose two sides are deliberately on different ' +
        'subjects, because here learning the subject is the point rather than the trap.',
        'If a category already has a subject ticked, you usually do not need this as ' +
        'well: the subject is doing that job.'
      ])
    ]);
    withPhrases.forEach(function (c) {
      restPanel.appendChild(pairRow(c, { name: VSR.REST, description: 'everything else' }, true));
    });
    body.appendChild(restPanel);

    // A real choice, with a default that is right most of the time, so it does not get
    // to interrupt the main question this step is asking.
    var ml = matchList();
    if (ml) {
      body.appendChild(el('div', { class: 'panel' }, [
        el('details', { class: 'adv' }, [
          el('summary', { text: 'Advanced: must a category\'s signals all hold at once?' }),
          el('div', { class: 'adv-body' }, [
            el('p', { class: 'lede' }, [
              'For a category with both words and example prompts, this is the difference ' +
              'between two decisions and one. Either is the default and is usually what ' +
              'you want.'
            ]),
            why('What the two settings actually build', [
              '<b>Either is enough</b> builds two decisions: the phrasing one, ranked ' +
              'above the word one. A long request gets caught by what it means, a short ' +
              'blunt one by the words in it.',
              '<b>Both must hold</b> builds a single, narrower decision that needs ' +
              'everything at once. That is what makes it safe to rank a category above ' +
              'all the others: it cannot grab a prompt that merely mentions one of its ' +
              'words.'
            ]),
            ml
          ])
        ])
      ]));
    }

    body.appendChild(navRow(null, 'Order'));
  }

  /* The old version of this said "no category has example phrasings yet" and left you
   * to work out which field on which step it meant. It now names the step, names the
   * field, shows what each category currently has, and offers the button. */
  function notEnoughPrompts(have) {
    var rows = el('div', { style: 'margin:14px 0 0' });
    cats().forEach(function (c) {
      var n = (c.phrases || []).length;
      rows.appendChild(el('div', { class: 'pair' }, [
        el('span', { class: 'grow' }, [el('b', { text: VSR.slug(c.name || 'unnamed') })]),
        el('span', { class: 'rulename' }, [
          n ? n + ' example prompt' + (n === 1 ? '' : 's') : 'no example prompts'
        ]),
        el('span', {
          class: 'why',
          style: n ? 'color:var(--w-ok)' : 'color:var(--w-warn)'
        }, [n ? 'ready to compare' : 'needs some'])
      ]));
    });

    return el('div', { class: 'panel' }, [
      el('div', { class: 'verdict meh' }, [
        el('b', {}, [have === 1
          ? 'Only one category has example prompts. '
          : 'Nothing to compare yet. ']),
        'A comparison works between two categories, so two of them need example ' +
        'prompts before there is anything to ask here.'
      ]),
      el('p', { class: 'lede', style: 'margin:0' }, [
        'Go back to ', el('b', {}, ['Signals']), ' and fill in the ',
        el('b', {}, ['Example prompts']), ' box for at least two categories. The ',
        el('b', {}, ['Insert an example']), ' dropdown at the top of each one fills it ' +
        'in for you if you would rather not start from a blank box.'
      ]),
      rows,
      el('div', { class: 'row', style: 'margin-top:16px' }, [
        el('button', {
          class: 'btn primary', type: 'button',
          onclick: function () { go(2); }
        }, ['\u2190 Back to Signals']),
        el('span', { class: 'hint' }, [
          'Or carry on. If your categories are already told apart by subject or by ' +
          'words alone, you do not need any comparisons at all.'
        ])
      ])
    ]);
  }

  function countPairs() {
    var n = 0;
    (state.plan.pairs || []).forEach(function (p) { if (p.b !== VSR.REST) n++; });
    return n;
  }

  function pairRow(a, b, isRest) {
    var bname = isRest ? VSR.REST : b.name;
    var on = pairOn(a.name, bname);
    var id = 'pair-' + VSR.slug(a.name) + '-' + (isRest ? 'rest' : VSR.slug(b.name));
    var other = isRest ? 'everything else' : VSR.slug(b.name);

    return el('div', { class: 'pair' + (on ? ' on' : '') }, [
      el('input', {
        type: 'checkbox', checked: on ? true : null, id: id,
        onchange: function () { togglePair(a.name, bname); render(); }
      }),
      el('label', { class: 'grow', for: id }, [
        // Say what the comparison answers, not what the rule will be called. The
        // generated name is only useful once you are reading the YAML.
        el('div', {}, [
          'Is it ', el('b', { text: VSR.slug(a.name) }), ' or ', el('b', { text: other }), '?'
        ]),
        on
          ? el('div', { class: 'rulename' }, ['builds a comparison called ' +
            (isRest ? VSR.slug(a.name) + '_vs_rest'
              : VSR.slug(a.name) + '_vs_' + VSR.slug(b.name))])
          : el('div', { class: 'rulename' }, ['off: the router will not compare these two'])
      ]),
      el('span', { class: 'why' }, [
        isRest
          ? ((a.domains && a.domains.length)
            ? 'Has a subject already, so probably not needed'
            : 'No subject ticked, so this is how it gets defined')
          : ''
      ])
    ]);
  }

  function matchList() {
    var wrap = el('div');
    var any = false;
    cats().forEach(function (c) {
      var hasKw = (c.keywords || []).length > 0;
      var hasPh = (c.phrases || []).length > 0 &&
        state.plan.pairs.some(function (p) {
          return VSR.slug(p.a) === VSR.slug(c.name) ||
            (p.b !== VSR.REST && VSR.slug(p.b) === VSR.slug(c.name));
        });
      if (!hasKw || !hasPh) return;
      any = true;
      wrap.appendChild(el('div', { class: 'pair' }, [
        el('span', { class: 'grow' }, [el('b', { text: VSR.slug(c.name) })]),
        el('div', { class: 'chips' }, [
          el('button', {
            type: 'button', class: 'chip',
            'aria-pressed': c.match === 'both' ? 'false' : 'true',
            onclick: function () { c.match = 'either'; save(); render(); }
          }, ['Either is enough']),
          el('button', {
            type: 'button', class: 'chip',
            'aria-pressed': c.match === 'both' ? 'true' : 'false',
            onclick: function () { c.match = 'both'; save(); render(); }
          }, ['Both must hold'])
        ])
      ]));
    });
    // Nothing to choose between: the caller hides the whole block rather than showing
    // an Advanced section that opens onto an apology.
    if (!any) return null;
    return wrap;
  }

  /* ---------------------------------------------------------------- step 4 -- */
  function stepOrder(body) {
    body.appendChild(el('div', { class: 'panel' }, [
      el('h3', { text: 'Which should the router try first?' }),
      el('p', { class: 'lede' }, [
        'Put the most specific at the top and the broadest at the bottom. If two match ' +
        'the same prompt, the one higher up wins.'
      ]),
      why('Why the order is the part that goes wrong', [
        'When more than one decision matches, the highest priority wins and nothing ' +
        'else about the config affects the outcome.',
        'This is where configs quietly break: every decision is legal, the router loads ' +
        'the file without a word of complaint, and one of them never fires because a ' +
        'broader decision above it matches first. The next step checks for exactly ' +
        'that.',
        'A category that asks for less than another is the broader one and belongs ' +
        'lower. Putting a category at the top is only safe if it cannot match a prompt ' +
        'that belongs somewhere else, which usually means every one of its signals has ' +
        'to hold at once.'
      ]),
      orderList(),
      el('p', { class: 'hint', style: 'margin:14px 0 0' },
        ['Priorities are generated from this order, ten apart, with each category\'s ' +
          'phrasing decision ranked above its word decision. The review step checks ' +
          'whether any of them can never win.'])
    ]));
    body.appendChild(navRow(null, 'Review'));
  }

  function orderList() {
    var wrap = el('div');
    var n = cats().length;
    cats().forEach(function (c, i) {
      wrap.appendChild(el('div', { class: 'pair' }, [
        el('span', { class: 'ord', text: String(i + 1) }),
        el('span', { class: 'grow' }, [
          el('b', { text: VSR.slug(c.name || 'unnamed') }),
          c.description ? el('span', { class: 'why' }, ['  \u00b7 ' + c.description]) : null
        ]),
        el('span', { class: 'rulename' }, ['priority ' + ((n - i) * 10 + 4)]),
        el('button', {
          class: 'btn tiny', type: 'button', disabled: i === 0,
          onclick: function () { swap(i, i - 1); }
        }, ['\u2191']),
        el('button', {
          class: 'btn tiny', type: 'button', disabled: i === n - 1,
          onclick: function () { swap(i, i + 1); }
        }, ['\u2193'])
      ]));
    });
    return wrap;
  }

  /* ---------------------------------------------------------------- step 5 -- */
  function stepReview(body) {
    var config = VSR.buildConfig(state.plan);
    var findings = VSR.analyse(config);
    var counts = VSR.summarise(findings);
    var values = VSR.buildValues(state.plan);
    var yaml = VSR.toYaml(values);

    var verdict, cls;
    if (counts.error) {
      cls = 'bad';
      verdict = counts.error + ' problem' + (counts.error === 1 ? '' : 's') +
        ' that will either be rejected or never fire.';
    } else if (counts.warn) {
      cls = 'meh';
      verdict = 'No errors. ' + counts.warn + ' thing' + (counts.warn === 1 ? '' : 's') +
        ' that will load and probably not do what you meant.';
    } else {
      cls = 'clean';
      verdict = 'Nothing to report. Every decision can be reached, every reference ' +
        'resolves, and no decision is shadowed by a higher one.';
    }

    var panel = el('div', { class: 'panel' }, [
      el('h3', { text: 'What the validator will not tell you' }),
      el('p', {
        class: 'lede',
        html: 'The router has its own validator and it is good: point a decision at a ' +
          'signal that does not exist and it will name it. What it cannot tell you is ' +
          'that a decision is perfectly legal and still never wins, because a ' +
          'higher-priority decision asks for a subset of its conditions and therefore ' +
          'matches whenever it does. These are the checks this repo\'s workbench runs, ' +
          'the same ones, running here.'
      }),
      el('div', { class: 'verdict ' + cls }, [
        el('b', { text: counts.error ? 'Needs work' : (counts.warn ? 'Worth a look' : 'Clean') }),
        verdict
      ])
    ]);
    findings.forEach(function (f) {
      panel.appendChild(el('div', { class: 'finding ' + f.level }, [
        el('div', { class: 'where', text: f.where }),
        el('p', { class: 'msg', text: f.message }),
        f.fix ? el('p', { class: 'fix' }, [el('b', {}, ['Fix: ']), f.fix]) : null
      ]));
    });
    if (window.VSR_HOST && window.VSR_HOST.validate) {
      panel.appendChild(hostValidateRow(config));
    }
    body.appendChild(panel);

    body.appendChild(decisionPanel(config));

    // When the plan came from a preset that mirrors a real lab config, offer the
    // actual file next to what was just generated, and say where the two differ.
    var ex = planExample();
    if (ex) body.appendChild(differencesPanel(ex));

    body.appendChild(el('div', { class: 'panel' }, [
      el('div', { class: 'row spread', style: 'margin-bottom:12px' }, [
        el('h3', { style: 'margin:0' }, ['The values file']),
        el('div', { class: 'row' }, [
          el('button', {
            class: 'btn', type: 'button', id: 'vw-copy',
            onclick: function (e) { copy(yaml, e.target); }
          }, ['Copy']),
          el('button', {
            class: 'btn primary', type: 'button',
            onclick: function () { download('values-semantic-router.yaml', yaml); }
          }, ['Download'])
        ])
      ]),
      el('p', { class: 'hint', style: 'margin:0 0 12px' }, [
        'Install with ',
        el('code', { text: 'helm upgrade --install semantic-router ... -f values-semantic-router.yaml' }),
        '. The chart stamps a checksum on the pod template, so every config change ' +
        'replaces the pod; there is no hot reload.'
      ]),
      el('pre', { class: 'yaml', text: yaml })
    ]));

    // Hosted in the workbench, "go and get the workbench" is useless advice: the
    // corpus is three tabs away. Say what is actually next in each host.
    var hosted = !!(window.VSR_HOST && window.VSR_HOST.validate);
    var labHref = hosted
      ? 'https://mastertheagent.com/solo/agentgateway-inference-task-routing-eks/'
      : '/solo/agentgateway-inference-task-routing-eks/';

    body.appendChild(el('div', { class: 'panel' }, [
      el('h3', { text: hosted ? 'What is left to find out' : 'What this page cannot do' }),
      el('p', {
        class: 'lede',
        html: 'Every check above is structural. None of it tells you whether your ' +
          'example prompts actually separate your categories, because that needs the router\'s ' +
          'embedding model, and that is a 768-dimension classifier on a volume in your ' +
          'cluster rather than anything that can run in a browser.'
      }),
      el('p', {
        class: 'lede',
        html: hosted
          ? 'Download the file, restart this workbench with <code>--values</code> pointed ' +
            'at it, and the Test tab will run a labelled corpus through the router and ' +
            'give you a confusion matrix and the signals behind every miss. It can do ' +
            'that before you deploy, by computing the signals locally from the router\'s ' +
            'own embeddings. This tab writes the file; Test tells you whether the file ' +
            'was right.'
          : 'For that part, take the file to <code>tools/vsr-workbench</code> in the ' +
            'solo-demos repo. It runs a labelled corpus through the router and gives you ' +
            'a confusion matrix and the signals behind every miss, and it can do that for ' +
            'a config you have not deployed yet by computing the signals locally from the ' +
            'router\'s own embeddings. This wizard writes the file; the workbench tells ' +
            'you whether the file was right.'
      }),
      el('div', { class: 'row' }, [
        el('button', {
          class: 'btn', type: 'button',
          onclick: function () {
            download('vsr-plan.json', JSON.stringify(state.plan, null, 2));
          }
        }, ['Download the answers as JSON']),
        el('a', {
          class: 'btn', href: labHref,
          target: hosted ? '_blank' : null,
          rel: hosted ? 'noopener' : null
        }, ['The lab this came from']),
        el('a', {
          class: 'btn', href: REPO, target: '_blank', rel: 'noopener'
        }, ['Run this yourself \u2197'])
      ])
    ]));

    body.appendChild(navRow('Order'));
  }

  function hostValidateRow(config) {
    var out = el('div', { style: 'margin-top:14px' });
    out.appendChild(el('div', { class: 'row' }, [
      el('button', {
        class: 'btn', type: 'button',
        onclick: function () {
          clear(status);
          status.appendChild(el('span', { class: 'hint' }, ['asking the router\u2026']));
          window.VSR_HOST.validate(config).then(function (res) {
            clear(status);
            status.appendChild(el('div', {
              class: 'verdict ' + (res.ok ? 'clean' : 'bad')
            }, [res.ok ? 'The running router accepts this config.' : (res.message || 'rejected')]));
          }).catch(function (err) {
            clear(status);
            status.appendChild(el('div', { class: 'verdict bad' }, [String(err)]));
          });
        }
      }, ['Also validate against the running router']),
      el('span', { class: 'hint' }, [window.VSR_HOST.name || ''])
    ]));
    var status = el('div', { style: 'margin-top:10px' });
    out.appendChild(status);
    return out;
  }

  function decisionPanel(config) {
    var rows = el('tbody');
    (config.routing.decisions || []).slice()
      .sort(function (a, b) { return (b.priority || 0) - (a.priority || 0); })
      .forEach(function (d) {
        var conds = el('td');
        ((d.rules || {}).conditions || []).forEach(function (c, i) {
          if (i) conds.appendChild(el('span', { class: 'op', text: ' ' + (d.rules.operator || 'AND') + ' ' }));
          conds.appendChild(el('code', { text: c.type + ':' + c.name }));
        });
        rows.appendChild(el('tr', {}, [
          el('td', { class: 'p', text: String(d.priority) }),
          el('td', { class: 'n', text: d.name }),
          conds,
          el('td', { class: 'n', text: ((d.modelRefs || [{}])[0] || {}).model || '' })
        ]));
      });

    var def = ((config.providers || {}).defaults || {}).default_model;
    rows.appendChild(el('tr', {}, [
      el('td', { class: 'p', text: '\u2014' }),
      el('td', { class: 'n' }, [el('span', { class: 'hint' }, ['nothing matched'])]),
      el('td', {}, [el('span', { class: 'hint' }, ['default_model'])]),
      el('td', { class: 'n', text: def || '' })
    ]));

    return el('div', { class: 'panel' }, [
      el('h3', { text: 'The decisions this makes, in the order the router tries them' }),
      el('div', { class: 'tablewrap' }, [
        el('table', { class: 'dec' }, [
          el('thead', {}, [el('tr', {}, [
            el('th', { text: 'Priority' }), el('th', { text: 'Decision' }),
            el('th', { text: 'Holds when' }), el('th', { text: 'Label' })
          ])]),
          rows
        ])
      ])
    ]);
  }

  /* ----------------------------------------------------------------- utils -- */
  function copy(text, btn) {
    var done = function () {
      var was = btn.textContent;
      btn.textContent = 'Copied';
      setTimeout(function () { btn.textContent = was; }, 1400);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallback(text, done); });
    } else {
      fallback(text, done);
    }
  }

  function fallback(text, done) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '-1000px';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); done(); } catch (e) { /* nothing to do */ }
    document.body.removeChild(ta);
  }

  function download(name, text) {
    var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  /* ---------------------------------------------------------------- render -- */
  var RENDER = {
    start: stepStart,
    categories: stepCategories,
    signals: stepSignals,
    confusions: stepConfusions,
    order: stepOrder,
    review: stepReview
  };

  function render() {
    // Every step after the first needs a plan. Arriving without one, via a saved step
    // or a bookmarked link, should land on Start rather than throw.
    if (state.step > 0 && !state.plan) state.step = 0;
    renderSteps();
    var body = document.getElementById('vw-body');
    clear(body);
    RENDER[STEPS[state.step].id](body);
  }

  function init() {
    var mount = document.getElementById('vw');
    if (!mount) return;
    mount.appendChild(el('nav', { id: 'vw-steps', class: 'steps', 'aria-label': 'Wizard steps' }));
    mount.appendChild(el('div', { id: 'vw-steps-compact', class: 'steps-compact' }));
    mount.appendChild(el('div', { id: 'vw-body' }));
    state.plan = null;
    render();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
