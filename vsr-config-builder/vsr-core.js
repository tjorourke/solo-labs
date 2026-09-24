/* vsr-core.js — everything about a vLLM Semantic Router config that needs no cluster.
 *
 * Three jobs, none of which touch the DOM or the network:
 *
 *   buildConfig(plan)   turn wizard answers into a router config block
 *   analyse(config)     the checks the router's own validator does not make
 *   toYaml(value)       emit the values file
 *
 * Loaded by the published page and by tools/vsr-workbench, so it stays a plain script
 * that hangs one object off window. No build step, no modules, no dependencies.
 *
 * analyse() is a port of tools/vsr-workbench/vsrlib/analyse.py. The two are kept in
 * step by tools/vsr-workbench/test_core_parity.py, which runs the same configs through
 * both and fails if a single finding differs.
 */
(function (root) {
  'use strict';

  /* ------------------------------------------------------------------ domains --
   * The fourteen labels belong to the MMLU-Pro classifier, not to the config. You
   * cannot invent a fifteenth: the model was trained on these and nothing else, which
   * is why the task-routing lab has to identify telco with a similarity bank instead.
   */
  var DOMAINS = [
    ['business', 'Business, corporate strategy, management, finance, marketing'],
    ['economics', 'Microeconomics, macroeconomics, financial markets, monetary policy, trade'],
    ['computer science', 'Algorithms, data structures, programming, software engineering'],
    ['engineering', 'Engineering disciplines, design, problem-solving, systems'],
    ['law', 'Legal principles, case law, statutory interpretation, legal procedures'],
    ['math', 'Mathematics, algebra, calculus, geometry, statistics'],
    ['physics', 'Physical laws, mechanics, thermodynamics, electromagnetism, quantum physics'],
    ['chemistry', 'Chemical reactions, molecular structures, laboratory techniques'],
    ['biology', 'Molecular biology, genetics, cell biology, ecology, evolution, anatomy'],
    ['health', 'Anatomy, physiology, diseases, treatments, preventive care, nutrition'],
    ['psychology', 'Cognitive processes, behavioral patterns, mental health, developmental psychology'],
    ['history', 'Historical events, time periods, cultures, civilizations'],
    ['philosophy', 'Philosophical traditions, ethics, logic, metaphysics, epistemology'],
    ['other', 'General knowledge and miscellaneous topics']
  ].map(function (d) { return { name: d[0], description: d[1] }; });

  /* -------------------------------------------------------------------- yaml --
   * A small emitter rather than a library, because the shapes here are known: maps,
   * lists, strings, numbers and booleans. Flow style is used for the same keys the
   * labs use it for, so a generated file and a hand-written one read alike.
   */
  // The other side of a similarity rule can be one named category or "everything else".
  var REST = '*';

  var FLOW_ITEMS = { conditions: 1, modelRefs: 1, backend_refs: 1 };
  var FLOW_LIST = { keywords: 1, candidates: 0 };

  function needsQuote(s) {
    if (s === '') return true;
    if (/^[\s]|[\s]$/.test(s)) return true;
    if (/[:#\[\]{}&*!|>'"%@`,]/.test(s)) return true;
    if (/^[-?]/.test(s)) return true;
    if (/^(true|false|null|yes|no|on|off|~)$/i.test(s)) return true;
    if (/^[+-]?(\d|\.\d)/.test(s) && /^[+-]?(\d+\.?\d*([eE][+-]?\d+)?|\.\d+)$/.test(s)) return true;
    return false;
  }

  function scalar(v) {
    if (v === null || v === undefined) return 'null';
    if (typeof v === 'boolean') return v ? 'true' : 'false';
    if (typeof v === 'number') return String(v);
    var s = String(v);
    if (!needsQuote(s)) return s;
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  }

  function isScalar(v) {
    return v === null || v === undefined || typeof v !== 'object';
  }

  function flowMap(obj) {
    var parts = [];
    for (var k in obj) {
      if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
      parts.push(scalar(k) + ': ' + (isScalar(obj[k]) ? scalar(obj[k]) : flowAny(obj[k])));
    }
    return '{' + parts.join(', ') + '}';
  }

  function flowAny(v) {
    if (isScalar(v)) return scalar(v);
    if (Array.isArray(v)) return '[' + v.map(flowAny).join(', ') + ']';
    return flowMap(v);
  }

  function emit(value, indent, key, out) {
    var pad = new Array(indent + 1).join(' ');
    var i, k;

    if (Array.isArray(value)) {
      if (value.length === 0) { return; }
      var itemsFlow = FLOW_ITEMS[key] === 1;
      for (i = 0; i < value.length; i++) {
        var item = value[i];
        if (isScalar(item)) {
          out.push(pad + '- ' + scalar(item));
        } else if (itemsFlow) {
          out.push(pad + '- ' + flowAny(item));
        } else {
          var sub = [];
          emit(item, indent + 2, null, sub);
          if (!sub.length) { out.push(pad + '- {}'); continue; }
          sub[0] = pad + '- ' + sub[0].slice(indent + 2);
          out.push.apply(out, sub);
        }
      }
      return;
    }

    for (k in value) {
      if (!Object.prototype.hasOwnProperty.call(value, k)) continue;
      var v = value[k];
      if (isScalar(v)) {
        out.push(pad + scalar(k) + ': ' + scalar(v));
      } else if (Array.isArray(v)) {
        if (v.length === 0) {
          out.push(pad + scalar(k) + ': []');
        } else if (FLOW_LIST[k] === 1 && v.every(isScalar)) {
          out.push(pad + scalar(k) + ': ' + flowAny(v));
        } else {
          out.push(pad + scalar(k) + ':');
          emit(v, indent + 2, k, out);
        }
      } else {
        var keys = Object.keys(v);
        if (!keys.length) { out.push(pad + scalar(k) + ': {}'); continue; }
        out.push(pad + scalar(k) + ':');
        emit(v, indent + 2, k, out);
      }
    }
  }

  function toYaml(value) {
    var out = [];
    emit(value, 0, null, out);
    return out.join('\n') + '\n';
  }

  /* ------------------------------------------------------------------- naming --
   * Label names end up in the request's model field and in condition references, so
   * they have to survive being typed twice.
   */
  function slug(s) {
    return String(s || '').toLowerCase().trim()
      .replace(/[^a-z0-9]+/g, '_')
      .replace(/^_+|_+$/g, '') || 'unnamed';
  }

  /* -------------------------------------------------------------------- build --
   *
   * plan = {
   *   endpoint:      where providers.models points (agentgateway forwards, so this is
   *                  required by the schema and never dialled on the ExtProc path)
   *   fallback:      the label for a prompt that matches nothing
   *   image:         {repository, tag}   optional, for the chart block
   *   categories: [{
   *     name, description,
   *     domains:  [names from DOMAINS],
   *     keywords: [terms],
   *     phrases:  [example prompts that sound like this category]
   *   }]                 ordered most specific first
   *   pairs: [{a, b}]    categories that get told apart by phrasing
   * }
   */
  function buildConfig(plan) {
    var cats = (plan.categories || []).filter(function (c) { return c.name; });
    var fallback = slug(plan.fallback || 'uncertain');
    var endpoint = plan.endpoint || 'model-gateway.agentgateway-system.svc.cluster.local:80';

    var labels = [];
    cats.forEach(function (c) { if (labels.indexOf(slug(c.name)) < 0) labels.push(slug(c.name)); });
    if (labels.indexOf(fallback) < 0) labels.push(fallback);

    /* --- signals --- */
    var complexity = [];
    var pairRule = {};   // "a|b" -> {name, band for a, band for b}
    (plan.pairs || []).forEach(function (p) {
      var a = cats.filter(function (c) { return slug(c.name) === slug(p.a); })[0];
      if (!a || !(a.phrases || []).length) return;

      // `b: "*"` means "against everything else", which is how the task-routing lab
      // identifies telco: the domain classifier has no label for it, so the easy bank
      // has to be every other subject the deployment sees.
      if (p.b === REST) {
        var rest = [];
        cats.forEach(function (c) {
          if (slug(c.name) === slug(a.name)) return;
          (c.phrases || []).forEach(function (ph) { if (rest.indexOf(ph) < 0) rest.push(ph); });
        });
        if (!rest.length) return;
        var rname = slug(a.name) + '_vs_rest';
        complexity.push({
          name: rname,
          description: (a.description || a.name) + ', against everything else',
          threshold: typeof p.threshold === 'number' ? p.threshold : 0.0,
          hard: { candidates: a.phrases.slice() },
          easy: { candidates: rest }
        });
        pairRule[slug(a.name) + '|' + REST] = { name: rname, self: 'hard', other: 'easy' };
        return;
      }

      var b = cats.filter(function (c) { return slug(c.name) === slug(p.b); })[0];
      if (!b || !(b.phrases || []).length) return;
      var name = slug(a.name) + '_vs_' + slug(b.name);
      complexity.push({
        name: name,
        description: (a.description || a.name) + ', against ' + (b.description || b.name),
        threshold: typeof p.threshold === 'number' ? p.threshold : 0.0,
        hard: { candidates: a.phrases.slice() },
        easy: { candidates: b.phrases.slice() }
      });
      pairRule[slug(a.name) + '|' + slug(b.name)] = { name: name, self: 'hard', other: 'easy' };
      pairRule[slug(b.name) + '|' + slug(a.name)] = { name: name, self: 'easy', other: 'hard' };
    });

    var keywords = [];
    cats.forEach(function (c) {
      var terms = (c.keywords || []).filter(Boolean);
      if (!terms.length) return;
      keywords.push({
        name: slug(c.name) + '_words',
        operator: 'OR',
        method: 'bm25',
        bm25_threshold: 0.01,
        keywords: terms.slice()
      });
    });

    /* --- decisions ---
     * Priority is the wizard's whole reason to exist. Categories are ordered most
     * specific first, each gets a band ten wide, and within a band the semantic
     * decision outranks the keyword one, so a verb in passing cannot overrule the
     * shape of the ask.
     */
    var decisions = [];
    var n = cats.length;
    cats.forEach(function (c, idx) {
      var label = slug(c.name);
      var base = (n - idx) * 10;
      var doms = (c.domains || []).filter(Boolean);
      var hasKw = (c.keywords || []).filter(Boolean).length > 0;

      var sim = [];
      cats.forEach(function (other) {
        if (slug(other.name) === label) return;
        var r = pairRule[label + '|' + slug(other.name)];
        if (r) sim.push({ type: 'complexity', name: r.name + ':' + r.self });
      });
      var restRule = pairRule[label + '|' + REST];
      if (restRule) sim.push({ type: 'complexity', name: restRule.name + ':' + restRule.self });
      // Deduplicate: one rule serves both directions of a pair.
      var seenSim = {};
      sim = sim.filter(function (s) {
        if (seenSim[s.name]) return false;
        seenSim[s.name] = 1;
        return true;
      });

      var refs = [{ model: label, use_reasoning: false }];

      function domainFanout(extra, suffix, priority, description) {
        // No subject and no other signal means there is nothing to match on. Emitting
        // the decision anyway produces `conditions: []`, which describes nothing and
        // reads as a complete config. Leave it out: the category keeps its model card,
        // and analyse() then reports it as a label no decision routes to, which is the
        // accurate complaint.
        if (!doms.length && !extra.length) return;

        // A decision has one operator, so "(business OR economics) AND keyword" cannot
        // be written as a single decision. With other conditions present, fan out one
        // decision per domain; with none, a single OR decision says it exactly.
        if (!doms.length) {
          decisions.push({
            name: label + suffix, description: description, priority: priority,
            rules: { operator: 'AND', conditions: extra.slice() },
            modelRefs: refs.slice()
          });
          return;
        }
        if (!extra.length) {
          decisions.push({
            name: label + suffix,
            description: description,
            priority: priority,
            rules: {
              operator: doms.length > 1 ? 'OR' : 'AND',
              conditions: doms.map(function (d) { return { type: 'domain', name: d }; })
            },
            modelRefs: refs.slice()
          });
          return;
        }
        doms.forEach(function (d, di) {
          decisions.push({
            name: label + suffix + (doms.length > 1 ? '_' + slug(d) : ''),
            description: description,
            priority: priority - di,
            rules: {
              operator: 'AND',
              conditions: [{ type: 'domain', name: d }].concat(extra)
            },
            modelRefs: refs.slice()
          });
        });
      }

      var kwCond = { type: 'keyword', name: label + '_words' };

      if (c.match === 'both' && sim.length && hasKw) {
        // One decision, every signal ANDed. Narrower, and what you want for a category
        // ranked above the rest: the task-routing lab can safely put telco top precisely
        // because both its signals must hold, so a code review with no network
        // vocabulary in it is still a code review.
        domainFanout(sim.concat([kwCond]), '', base + 4,
          (c.description || c.name) + ', on every signal together');
      } else {
        // Two decisions, so a long ask is caught by its meaning and a short one by its
        // verb. The semantic decision outranks the keyword one: a verb in passing must
        // not overrule the shape of the ask.
        if (sim.length) {
          domainFanout(sim, '_semantic', base + 4,
            (c.description || c.name) + ', by the shape of the ask');
        }
        if (hasKw) {
          domainFanout([kwCond], '_keyword', base + 2,
            (c.description || c.name) + ', short form');
        }
        if (!sim.length && !hasKw) {
          domainFanout([], '', base + 4, c.description || c.name);
        }
      }
    });

    /* --- assemble --- */
    var config = {
      version: 'v0.3',
      listeners: [],
      providers: {
        defaults: { default_model: fallback },
        models: labels.map(function (l) {
          return {
            name: l,
            backend_refs: [{ name: 'gateway', endpoint: endpoint, weight: 1 }]
          };
        })
      },
      routing: {
        signals: {},
        decisions: decisions,
        modelCards: labels.map(function (l) { return { name: l }; })
      }
    };
    if (complexity.length) config.routing.signals.complexity = complexity;
    if (keywords.length) config.routing.signals.keywords = keywords;
    var usedDomains = {};
    cats.forEach(function (c) { (c.domains || []).forEach(function (d) { usedDomains[d] = 1; }); });
    if (Object.keys(usedDomains).length) config.routing.signals.domains = DOMAINS.slice();

    config.global = {
      router: { strategy: 'priority' },
      stores: {
        semantic_cache: { enabled: false },
        memory: { embedding_model: 'mmbert' },
        vector_store: { embedding_model: 'mmbert' }
      },
      observability: { tracing: { enabled: false } }
    };
    return config;
  }

  function buildValues(plan) {
    var doc = {
      persistence: { storageClassName: plan.storageClassName || 'gp3', size: plan.volumeSize || '20Gi' },
      image: {
        repository: (plan.image && plan.image.repository) ||
          'ghcr.io/vllm-project/semantic-router/extproc@sha256',
        tag: (plan.image && plan.image.tag) ||
          'c0519e91c9dfe69066b25766aef40a38b5474e17dcbb1b58c791c451646334e0',
        pullPolicy: 'IfNotPresent'
      },
      resources: {
        requests: { cpu: '1', memory: '3Gi' },
        limits: { cpu: '2', memory: '7Gi' }
      },
      config: buildConfig(plan)
    };
    return doc;
  }

  /* ------------------------------------------------------------------ analyse --
   * Port of vsrlib/analyse.py. Kept in the same order so the two can be diffed.
   */
  function signalsOf(config, kind) {
    var routing = config.routing || {};
    var signals = routing.signals || {};
    return signals[kind] || [];
  }

  function decisionsOf(config) {
    return (config.routing || {}).decisions || [];
  }

  function conditionKey(cond) {
    return [cond.type, String(cond.name === undefined ? '' : cond.name)];
  }

  // Findings are compared against the Python implementation, which formats a float as
  // "0.0" where JS gives "0". Match Python so the two read identically.
  function pyfloat(x) {
    var n = parseFloat(x) || 0.0;
    var s = String(n);
    return /[.eE]/.test(s) ? s : s + '.0';
  }

  function rpartition(s, sep) {
    var i = s.lastIndexOf(sep);
    if (i < 0) return ['', '', s];
    return [s.slice(0, i), sep, s.slice(i + sep.length)];
  }

  function analyse(config, liveConfig) {
    var findings = [];
    function add(level, where, message, fix) {
      findings.push({ level: level, where: where, message: message, fix: fix || null });
    }
    function names(list) {
      var s = {};
      list.forEach(function (r) { s[r.name] = 1; });
      return s;
    }

    var keywordNames = names(signalsOf(config, 'keywords'));
    var complexityNames = names(signalsOf(config, 'complexity'));
    var domainNames = names(signalsOf(config, 'domains'));
    var cards = names((config.routing || {}).modelCards || []);
    var provided = names(((config.providers || {}).models) || []);
    var decisions = decisionsOf(config);

    // --- decisions that describe nothing ---
    // A decision with no conditions is not a reference error, so the router's validator
    // passes it, and it reads like a finished decision. What it actually says is "match
    // on nothing", which is either dead or matches everything depending on the build.
    decisions.forEach(function (d) {
      if (!(((d.rules || {}).conditions) || []).length) {
        add('error', 'decisions[' + (d.name || '<unnamed>') + ']',
          'has no conditions, so it does not describe anything',
          'give it at least one signal, or drop the decision');
      }
    });

    // --- references ---
    decisions.forEach(function (d) {
      var name = d.name || '<unnamed>';
      var conds = ((d.rules || {}).conditions) || [];
      conds.forEach(function (cond) {
        var kv = conditionKey(cond), kind = kv[0], ref = kv[1];
        if (kind === 'keyword' && !keywordNames[ref]) {
          add('error', 'decisions[' + name + ']', 'keyword rule "' + ref + '" is not defined',
            'add it under routing.signals.keywords, or fix the spelling');
        } else if (kind === 'complexity') {
          var p = rpartition(ref, ':');
          var rule = p[0] || ref;
          var wanted = ref.indexOf(':') >= 0 ? p[2] : 'hard';
          if (!complexityNames[rule]) {
            add('error', 'decisions[' + name + ']',
              'similarity rule "' + rule + '" is not defined',
              'add it under routing.signals.complexity, or fix the spelling');
          } else if (['hard', 'easy', 'medium'].indexOf(wanted) < 0) {
            add('error', 'decisions[' + name + ']',
              '"' + ref + '" asks for band "' + wanted + '"; only hard, easy and medium exist');
          }
        } else if (kind === 'domain' && !domainNames[ref]) {
          add('error', 'decisions[' + name + ']',
            'domain "' + ref + '" is not listed under routing.signals.domains',
            'the fourteen domain names are fixed by the classifier');
        }
      });
      (d.modelRefs || []).forEach(function (ref) {
        var model = ref.model;
        if (!cards[model]) {
          add('error', 'decisions[' + name + ']',
            'routes to "' + model + '", which is not in routing.modelCards');
        }
        if (!provided[model]) {
          add('warn', 'decisions[' + name + ']',
            '"' + model + '" is not under providers.models, so the router cannot name it');
        }
      });
    });

    // --- the default ---
    var defaults = ((config.providers || {}).defaults) || {};
    var def = defaults.default_model;
    if (!def) {
      add('warn', 'providers.defaults', 'no default_model, so an unmatched prompt has no label');
    } else if (!cards[def]) {
      add('error', 'providers.defaults',
        'default_model "' + def + '" is not in routing.modelCards');
    }

    // --- duplicates and priority ---
    var seen = {};
    decisions.forEach(function (d) {
      (seen[d.name] = seen[d.name] || []).push(d);
    });
    Object.keys(seen).forEach(function (name) {
      if (seen[name].length > 1) {
        add('error', 'decisions[' + name + ']',
          'defined ' + seen[name].length + ' times; the router keeps one and drops the rest');
      }
    });
    var priorities = {};
    decisions.forEach(function (d) {
      var p = parseInt(d.priority, 10) || 0;
      (priorities[p] = priorities[p] || []).push(d.name);
    });
    Object.keys(priorities).map(Number).sort(function (a, b) { return b - a; })
      .forEach(function (prio) {
        var ns = priorities[prio];
        if (ns.length > 1) {
          add('warn', 'decisions',
            'priority ' + prio + ' is shared by ' + ns.join(', ') + '; which one wins is not defined',
            'give each decision its own priority');
        }
      });

    // --- unused signals ---
    var used = {};
    decisions.forEach(function (d) {
      (((d.rules || {}).conditions) || []).forEach(function (cond) {
        var kv = conditionKey(cond), kind = kv[0], ref = kv[1];
        var base = kind === 'complexity' ? (rpartition(ref, ':')[0] || ref) : ref;
        used[kind + '\u0000' + base] = 1;
      });
    });
    signalsOf(config, 'keywords').forEach(function (rule) {
      if (!used['keyword\u0000' + rule.name]) {
        add('note', 'signals.keywords[' + rule.name + ']', 'defined but no decision uses it');
      }
    });
    signalsOf(config, 'complexity').forEach(function (rule) {
      if (!used['complexity\u0000' + rule.name]) {
        add('note', 'signals.complexity[' + rule.name + ']', 'defined but no decision uses it');
      }
    });

    // --- models nothing routes to ---
    var routed = {};
    decisions.forEach(function (d) {
      (d.modelRefs || []).forEach(function (r) { routed[r.model] = 1; });
    });
    Object.keys(cards).sort().forEach(function (card) {
      if (!routed[card] && card !== def) {
        add('warn', 'modelCards[' + card + ']',
          'no decision routes to it, so the router can never choose it');
      }
    });

    // --- shadowing ---
    findings = findings.concat(shadowing(decisions));

    // --- similarity rule sanity ---
    signalsOf(config, 'complexity').forEach(function (rule) {
      var name = rule.name;
      var hard = ((rule.hard || {}).candidates) || [];
      var easy = ((rule.easy || {}).candidates) || [];
      if (!hard.length || !easy.length) {
        add('error', 'signals.complexity[' + name + ']',
          'needs candidates in both hard and easy; one empty bank disables the rule');
      }
      var easySet = {};
      easy.forEach(function (e) { easySet[e] = 1; });
      var overlap = hard.filter(function (h) { return easySet[h]; })
        .filter(function (v, i, a) { return a.indexOf(v) === i; }).sort();
      if (overlap.length) {
        add('warn', 'signals.complexity[' + name + ']',
          overlap.length + ' phrase(s) appear in both banks, which cancels out',
          'first one: ' + String(overlap[0]).slice(0, 60));
      }
      if (hard.length < 3 || easy.length < 3) {
        add('note', 'signals.complexity[' + name + ']',
          'small banks (' + hard.length + ' hard, ' + easy.length + ' easy); the score is a max, ' +
          'so one odd phrase decides it');
      }
      var threshold = parseFloat(rule.threshold) || 0.0;
      if (threshold < 0) {
        add('error', 'signals.complexity[' + name + ']',
          'negative threshold ' + pyfloat(threshold) + ' inverts hard and easy');
      }
    });

    if (liveConfig) findings = findings.concat(drift(config, liveConfig));
    return findings;
  }

  function shadowing(decisions) {
    var out = [];
    decisions.forEach(function (low) {
      var lrules = low.rules || {};
      if (String(lrules.operator || 'AND').toUpperCase() !== 'AND') return;
      var lconds = (lrules.conditions || []).map(function (c) { return conditionKey(c).join('\u0000'); });
      if (!lconds.length) return;
      var lset = {};
      lconds.forEach(function (c) { lset[c] = 1; });
      decisions.forEach(function (high) {
        if (high === low) return;
        if ((parseInt(high.priority, 10) || 0) <= (parseInt(low.priority, 10) || 0)) return;
        var hrules = high.rules || {};
        if (String(hrules.operator || 'AND').toUpperCase() !== 'AND') return;
        var hconds = (hrules.conditions || []).map(function (c) { return conditionKey(c).join('\u0000'); });
        if (!hconds.length) return;
        var subset = hconds.every(function (c) { return lset[c]; });
        if (!subset) return;
        var lmodel = ((low.modelRefs || [{}])[0] || {}).model;
        var hmodel = ((high.modelRefs || [{}])[0] || {}).model;
        if (lmodel === hmodel) {
          out.push({
            level: 'note', where: 'decisions[' + low.name + ']',
            message: 'never wins: ' + high.name + ' at priority ' + high.priority +
              ' asks for less and routes to the same model, so this is dead weight',
            fix: 'drop it, or give it a condition the other does not have'
          });
        } else {
          out.push({
            level: 'error', where: 'decisions[' + low.name + ']',
            message: 'can never win: ' + high.name + ' at priority ' + high.priority +
              ' matches whenever this does, and routes to ' + hmodel + ' instead of ' + lmodel,
            fix: 'raise this above ' + high.priority + ', or narrow ' + high.name
          });
        }
      });
    });
    return out;
  }

  function drift(config, liveConfig) {
    var out = [];
    function nameSet(cfg, kind) {
      var s = {};
      signalsOf(cfg, kind).forEach(function (r) { s[r.name] = 1; });
      return s;
    }
    ['keywords', 'complexity'].forEach(function (kind) {
      var mine = nameSet(config, kind), theirs = nameSet(liveConfig, kind);
      Object.keys(theirs).sort().forEach(function (extra) {
        if (!mine[extra]) {
          out.push({
            level: 'warn', where: 'signals.' + kind + '[' + extra + ']',
            message: 'the running router has this and the file does not',
            fix: 'pull it into the file, or it dies with the pod'
          });
        }
      });
      Object.keys(mine).sort().forEach(function (extra) {
        if (!theirs[extra]) {
          out.push({
            level: 'note', where: 'signals.' + kind + '[' + extra + ']',
            message: 'in the file but not running; the router has not been redeployed since this was added',
            fix: null
          });
        }
      });
    });

    var mineD = {}, theirsD = {};
    decisionsOf(config).forEach(function (d) { mineD[d.name] = 1; });
    decisionsOf(liveConfig).forEach(function (d) { theirsD[d.name] = 1; });
    Object.keys(theirsD).sort().forEach(function (extra) {
      if (!mineD[extra]) {
        out.push({
          level: 'warn', where: 'decisions[' + extra + ']',
          message: 'the running router has this decision and the file does not',
          fix: 'pull it into the file, or it dies with the pod'
        });
      }
    });
    Object.keys(mineD).sort().forEach(function (extra) {
      if (!theirsD[extra]) {
        out.push({
          level: 'note', where: 'decisions[' + extra + ']',
          message: 'in the file but not running; redeploy to apply it', fix: null
        });
      }
    });

    var liveRules = {};
    signalsOf(liveConfig, 'complexity').forEach(function (r) { liveRules[r.name] = r; });
    signalsOf(config, 'complexity').forEach(function (rule) {
      var other = liveRules[rule.name];
      if (!other) return;
      var mineT = parseFloat(rule.threshold) || 0.0;
      var theirsT = parseFloat(other.threshold) || 0.0;
      if (Math.abs(mineT - theirsT) > 1e-9) {
        out.push({
          level: 'warn', where: 'signals.complexity[' + rule.name + ']',
          message: 'threshold is ' + pyfloat(mineT) + ' in the file and ' + pyfloat(theirsT) +
            ' on the running router',
          fix: 'the running value is the one that was tested'
        });
      }
      ['hard', 'easy'].forEach(function (bank) {
        var a = ((rule[bank] || {}).candidates) || [];
        var b = ((other[bank] || {}).candidates) || [];
        if (a.length !== b.length || a.some(function (v, i) { return v !== b[i]; })) {
          out.push({
            level: 'warn', where: 'signals.complexity[' + rule.name + '].' + bank,
            message: bank + ' bank differs from the running router (' + a.length +
              ' phrases here, ' + b.length + ' there)',
            fix: null
          });
        }
      });
    });
    return out;
  }

  function summarise(findings) {
    var counts = { error: 0, warn: 0, note: 0 };
    findings.forEach(function (f) { counts[f.level] = (counts[f.level] || 0) + 1; });
    return counts;
  }

  /* ------------------------------------------------------------- corpus check --
   * The one test that needs no embeddings: a prompt used to define a similarity bank
   * scores against itself, so a corpus that overlaps a bank proves nothing.
   */
  function holdout(plan, corpus) {
    var bank = {};
    (plan.categories || []).forEach(function (c) {
      (c.phrases || []).forEach(function (p) { bank[String(p).trim().toLowerCase()] = c.name; });
    });
    var hits = [];
    (corpus || []).forEach(function (row) {
      var key = String(row.prompt || '').trim().toLowerCase();
      if (bank[key]) hits.push({ prompt: row.prompt, bank: bank[key] });
    });
    return hits;
  }

  root.VSR = {
    DOMAINS: DOMAINS,
    REST: REST,
    slug: slug,
    toYaml: toYaml,
    buildConfig: buildConfig,
    buildValues: buildValues,
    analyse: analyse,
    drift: drift,
    summarise: summarise,
    holdout: holdout
  };
})(typeof window !== 'undefined' ? window : globalThis);
