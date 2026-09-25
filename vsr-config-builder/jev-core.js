/* jev-core.js — the Jev side of the wizard. No DOM, no network.
 *
 * vsr-core.js turns a plan into a vLLM Semantic Router values file. This does the same
 * job for Jev, TypeSafe's hosted classifier, which is configured completely differently:
 * there are no signals, keyword lists or embedding banks. You ask Jev typed Choice
 * questions, each with a description per answer, and it returns one answer per question
 * with a probability for every option.
 *
 * What turns those answers into the one label the gateway routes on is the ExtProc
 * adapter from the Part 5 guide (agentgateway-inference-jev-routing-eks). The profile
 * this file writes is that adapter's configuration, not a Jev API object: `questions`
 * is sent to Jev as-is, and everything around it (thresholds, fallback, rules) is read
 * by the adapter.
 *
 * Two profile shapes come out of here:
 *
 *   single  One question whose answers are the labels. This is the shape the reference
 *           adapter reads today (`questionId` + `fallback`), and the output runs on it
 *           unchanged.
 *
 *   rules   Several questions combined by an ordered rule list, first match wins. This
 *           is how Part 4's router config maps across, because the router combines
 *           separate signals with prioritised decisions. The reference adapter does not
 *           read this shape yet; the page says so wherever it is produced.
 *
 * plan = {
 *   model, minConfidence, minMargin, requestTimeoutMs,
 *   fallback:  the label written when no rule matches, or an answer is not confident
 *   questions: [{ id, instructions, choices: [{ name, description }] }]
 *   rules:     [{ when: { questionId: choice, ... }, task: label }]   in order
 *   deploy:    { namespace, gateway, profileName, image }
 * }
 */
(function (root) {
  'use strict';

  // The reference adapter's own limits, from src/profile.go. Checking them here means a
  // profile that passes the wizard also passes the adapter's `-check-profile`.
  var LABEL = /^[a-z][a-z0-9_-]{0,62}$/;
  var MODEL = /^jev-[a-zA-Z0-9.-]+$/;
  var MAX_QUESTIONS = 16;
  var MIN_CHOICES = 2;
  var MAX_CHOICES = 255;
  var MAX_PROFILE = 32768;

  var ENDPOINT = 'https://api.typesafe.ai/v1/systemone';

  function label(s) {
    var out = String(s || '').toLowerCase().trim()
      .replace(/[^a-z0-9_-]+/g, '_')
      .replace(/^[_-]+|[_-]+$/g, '');
    if (!out) return 'unnamed';
    if (!/^[a-z]/.test(out)) out = 'x_' + out;
    return out.slice(0, 63);
  }

  function questions(plan) {
    return (plan.questions || []).filter(function (q) { return q && q.id; });
  }

  function choicesOf(q) {
    return (q.choices || []).filter(function (c) { return c && c.name; });
  }

  function whenKeys(rule) {
    return Object.keys((rule && rule.when) || {}).filter(function (k) {
      return rule.when[k] !== undefined && rule.when[k] !== null && rule.when[k] !== '';
    });
  }

  /* -------------------------------------------------------------------- shape --
   * The single shape is only honest when the rules say nothing the adapter would not
   * already do on its own: every answer is its own label, and the fallback is one of
   * the answers (the adapter rejects a profile whose fallback is not a choice).
   */
  function isSingle(plan) {
    var qs = questions(plan);
    if (qs.length !== 1) return false;
    var q = qs[0];
    var names = choicesOf(q).map(function (c) { return label(c.name); });
    var fb = label(plan.fallback);
    if (names.indexOf(fb) < 0) return false;

    var identity = {};
    var ok = (plan.rules || []).every(function (r) {
      var keys = whenKeys(r);
      if (keys.length !== 1 || keys[0] !== q.id) return false;
      if (label(r.when[q.id]) !== label(r.task)) return false;
      identity[label(r.task)] = true;
      return true;
    });
    if (!ok) return false;
    return names.every(function (n) { return identity[n] || n === fb; });
  }

  function questionObject(q) {
    var criteria = {};
    choicesOf(q).forEach(function (c) {
      criteria[label(c.name)] = String(c.description || '').trim();
    });
    return {
      type: 'choice',
      instructions: String(q.instructions || '').trim(),
      criteria: criteria
    };
  }

  function buildProfile(plan) {
    var qs = questions(plan);
    var qobj = {};
    qs.forEach(function (q) { qobj[label(q.id)] = questionObject(q); });

    if (isSingle(plan)) {
      return {
        model: plan.model,
        questionId: label(qs[0].id),
        minConfidence: num(plan.minConfidence),
        minMargin: num(plan.minMargin),
        fallback: label(plan.fallback),
        requestTimeoutMs: num(plan.requestTimeoutMs),
        questions: qobj
      };
    }
    return {
      model: plan.model,
      minConfidence: num(plan.minConfidence),
      minMargin: num(plan.minMargin),
      requestTimeoutMs: num(plan.requestTimeoutMs),
      fallback: label(plan.fallback),
      questions: qobj,
      rules: (plan.rules || []).map(function (r) {
        var when = {};
        whenKeys(r).forEach(function (k) { when[label(k)] = label(r.when[k]); });
        return { when: when, task: label(r.task) };
      })
    };
  }

  function num(v) {
    var n = Number(v);
    return isFinite(n) ? n : v;
  }

  /* One rule per line, the way config/task-routing-rules.json in the Part 5 guide is
   * laid out: a rule list reads as a table, and JSON.stringify's default spreads each
   * one over five lines. */
  function profileJson(plan) {
    var p = buildProfile(plan);
    if (!p.rules) return JSON.stringify(p, null, 2) + '\n';
    var rules = p.rules;
    delete p.rules;
    var head = JSON.stringify(p, null, 2).replace(/\n\}$/, '');
    var body = rules.map(function (r) {
      return '    ' + JSON.stringify(r).replace(/":/g, '": ').replace(/,"/g, ', "');
    }).join(',\n');
    return head + ',\n  "rules": [\n' + body + (rules.length ? '\n' : '') + '  ]\n}\n';
  }

  /* ----------------------------------------------------------------- evaluate --
   * What the adapter does with one set of answers. `answers` is {questionId: choice},
   * with a missing or empty value standing for "not confident enough to count".
   */
  function evaluate(plan, answers) {
    var fb = label(plan.fallback);
    var rules = plan.rules || [];
    for (var i = 0; i < rules.length; i++) {
      var r = rules[i];
      var keys = whenKeys(r);
      var hit = keys.every(function (k) {
        return answers[k] && label(answers[k]) === label(r.when[k]);
      });
      if (hit) return { task: label(r.task), rule: i };
    }
    return { task: fb, rule: -1 };
  }

  /* Every label the profile can write: the rule targets plus the fallback. */
  function labels(plan) {
    var out = [];
    (plan.rules || []).forEach(function (r) {
      var t = label(r.task);
      if (r.task && out.indexOf(t) < 0) out.push(t);
    });
    var fb = label(plan.fallback);
    if (out.indexOf(fb) < 0) out.push(fb);
    return out;
  }

  /* ------------------------------------------------------------------ analyse --
   * Same finding shape as vsr-core.js ({level, where, message, fix}), so the review
   * step renders both with one function.
   */
  function analyse(plan) {
    var f = [];
    function add(level, where, message, fix) {
      f.push({ level: level, where: where, message: message, fix: fix || '' });
    }

    var qs = questions(plan);
    var single = isSingle(plan);

    if (!MODEL.test(String(plan.model || ''))) {
      add('error', 'model', 'The adapter only accepts a Jev model name such as jev-1.13.0.',
        'Set the model to the Jev version you are using.');
    }
    [['minConfidence', plan.minConfidence], ['minMargin', plan.minMargin]].forEach(function (kv) {
      var v = Number(kv[1]);
      if (!(v >= 0 && v <= 1) || kv[1] === '' || kv[1] === null || kv[1] === undefined) {
        add('error', kv[0], kv[0] + ' has to be a number between 0 and 1.', '');
      }
    });
    var t = Number(plan.requestTimeoutMs);
    if (!(t >= 100 && t <= 10000)) {
      add('error', 'requestTimeoutMs', 'The adapter accepts a timeout between 100 and 10000 milliseconds.', '');
    }
    if (Number(plan.minConfidence) === 0 && Number(plan.minMargin) === 0) {
      add('warn', 'thresholds',
        'Both thresholds are 0, so every answer counts however unsure Jev is, and the ' +
        'fallback is only used when no rule matches.',
        'Start around 0.8 confidence and 0.2 margin, then tune against labelled prompts.');
    }

    if (!qs.length) {
      add('error', 'questions', 'There are no questions, so there is nothing to ask Jev.',
        'Add at least one question.');
    }
    if (qs.length > MAX_QUESTIONS) {
      add('error', 'questions', 'The adapter accepts at most ' + MAX_QUESTIONS + ' questions per profile.', '');
    }

    var seenQ = {};
    var choiceSets = {};
    qs.forEach(function (q) {
      var id = label(q.id);
      var where = 'questions.' + id;
      if (!LABEL.test(String(q.id))) {
        add('error', where, '"' + q.id + '" is not a valid question id. It is written as "' + id + '".',
          'Use lower case letters, digits, _ and -, starting with a letter.');
      }
      if (seenQ[id]) add('error', where, 'Two questions share the id "' + id + '".', 'Rename one of them.');
      seenQ[id] = true;
      if (!String(q.instructions || '').trim()) {
        add('error', where + '.instructions', 'The question has no instructions. The adapter rejects a question without them.',
          'Say what Jev is classifying, and that text in the request is data rather than instructions.');
      }
      var cs = choicesOf(q);
      if (cs.length < MIN_CHOICES) {
        add('error', where, 'A Choice question needs at least ' + MIN_CHOICES + ' answers.', '');
      }
      if (cs.length > MAX_CHOICES) {
        add('error', where, 'A Choice question accepts at most ' + MAX_CHOICES + ' answers.', '');
      }
      var seenC = {};
      choiceSets[id] = {};
      cs.forEach(function (c) {
        var n = label(c.name);
        if (seenC[n]) add('error', where + '.' + n, 'Two answers share the name "' + n + '".', 'Rename one of them.');
        seenC[n] = true;
        choiceSets[id][n] = true;
        if (!LABEL.test(String(c.name))) {
          add('warn', where + '.' + n, '"' + c.name + '" is written as "' + n + '" in the profile.', '');
        }
        if (!String(c.description || '').trim()) {
          add('warn', where + '.' + n,
            'This answer has no description, so Jev has only its name to go on. The ' +
            'description is the definition of the answer.',
            'Say what belongs here, and what does not.');
        }
      });
      // An answer for "none of these" gives Jev somewhere to put a request that fits
      // nothing, rather than forcing it into the closest real category.
      if (cs.length >= MIN_CHOICES && !cs.some(function (c) {
        return /^(other|uncertain|unknown|none|unclear)$/.test(label(c.name)) || label(c.name) === label(plan.fallback);
      })) {
        add('note', where,
          'None of the answers is a way of saying "none of these". Jev has to pick one, ' +
          'so a request that fits nothing lands on the closest answer.',
          'Add an answer such as other, described as anything that fits none of the above.');
      }
    });

    var fb = label(plan.fallback);
    if (!String(plan.fallback || '').trim()) {
      add('error', 'fallback', 'There is no fallback label.', 'Name the label to write when nothing matches.');
    }

    // Rules.
    var rules = plan.rules || [];
    if (!single && !rules.length && qs.length) {
      add('error', 'rules', 'There are no rules, so every request gets the fallback label.',
        'Add a rule for each label you want to route on.');
    }
    var usedQ = {};
    var usedC = {};
    rules.forEach(function (r, i) {
      var where = 'rules[' + (i + 1) + ']';
      var keys = whenKeys(r);
      if (!String(r.task || '').trim()) {
        add('error', where, 'This rule has no label to write.', 'Give it a label.');
      } else if (!LABEL.test(label(r.task))) {
        add('error', where, '"' + r.task + '" is not a valid label.', '');
      }
      keys.forEach(function (k) {
        var qk = label(k);
        usedQ[qk] = true;
        if (!choiceSets[qk]) {
          add('error', where, 'The rule refers to a question called "' + k + '" that does not exist.',
            'Pick one of the questions, or remove the condition.');
          return;
        }
        var c = label(r.when[k]);
        if (!choiceSets[qk][c]) {
          add('error', where, 'The rule waits for "' + c + '" from ' + qk + ', which is not one of its answers.',
            'Pick one of that question\'s answers.');
        }
        usedC[qk + '.' + c] = true;
      });
      if (!keys.length && i < rules.length - 1) {
        add('error', where,
          'This rule has no conditions, so it matches every request and nothing below it can ever be reached.',
          'Add a condition, or move it to the bottom.');
      } else if (!keys.length) {
        add('warn', where,
          'This rule has no conditions, so it matches everything that reaches it and the ' +
          'fallback is never written.',
          'Remove it and let the fallback do this job, or add a condition.');
      }

      // Shadowing: an earlier rule whose conditions are a subset of this one's matches
      // every request this one does, and wins because it is first.
      for (var j = 0; j < i; j++) {
        var a = rules[j];
        var ak = whenKeys(a);
        if (!ak.length) continue;   // already reported above
        var subset = ak.every(function (k) {
          return r.when && label(r.when[k] || '') === label(a.when[k]) && r.when[k];
        });
        if (subset) {
          var same = label(a.task) === label(r.task);
          add(same ? 'warn' : 'error', where,
            same
              ? 'Rule ' + (j + 1) + ' above already writes ' + label(r.task) + ' for every request this rule matches, so this one does nothing.'
              : 'This rule can never match. Rule ' + (j + 1) + ' above asks for less (' +
                describe(a) + ') and writes ' + label(a.task) + ' first, every time this one would.',
            same ? 'Remove it.' : 'Move this rule above rule ' + (j + 1) + ', or narrow rule ' + (j + 1) + '.');
          break;
        }
      }
    });

    if (!single) {
      qs.forEach(function (q) {
        var id = label(q.id);
        if (rules.length && !usedQ[id]) {
          add('warn', 'questions.' + id,
            'No rule uses this question. Jev still answers it on every request, which costs ' +
            'tokens and changes nothing.',
            'Use it in a rule, or remove it.');
        }
      });
    }

    var size = profileJson(plan).length;
    if (size > MAX_PROFILE) {
      add('error', 'profile', 'The profile is ' + size + ' bytes. The adapter reads at most ' + MAX_PROFILE + '.',
        'Shorten the descriptions.');
    }

    if (!single && qs.length) {
      add('note', 'profile',
        'This profile uses several questions or a rule list. The reference Jev adapter ' +
        'reads the single-question shape today, so running this profile needs an adapter ' +
        'that supports rules.', '');
    }
    if (qs.length === 1 && !single && choiceSets[label(qs[0].id)] &&
        !choiceSets[label(qs[0].id)][fb]) {
      add('note', 'fallback',
        'The fallback "' + fb + '" is not one of the answers. The reference adapter requires ' +
        'it to be, so with one question it is simplest to add it as an answer.', '');
    }
    return f;
  }

  function describe(rule) {
    return whenKeys(rule).map(function (k) { return label(k) + ' = ' + label(rule.when[k]); }).join(' and ');
  }

  function summarise(findings) {
    var c = { error: 0, warn: 0, note: 0 };
    findings.forEach(function (x) { c[x.level] = (c[x.level] || 0) + 1; });
    return c;
  }

  /* ---------------------------------------------------------------- examples -- */

  // The body the adapter posts to Jev. `questions` goes across exactly as it sits in
  // the profile; nothing else from the profile is sent.
  function requestJson(plan, text) {
    var p = buildProfile(plan);
    var q = p.questionId ? pick(p.questions, [p.questionId]) : p.questions;
    return JSON.stringify({ model: p.model, state: text, questions: q }, null, 2) + '\n';
  }

  function pick(obj, keys) {
    var o = {};
    keys.forEach(function (k) { o[k] = obj[k]; });
    return o;
  }

  // A response shaped like Jev's, with the measured values left as placeholders: a
  // plausible-looking confidence would be a made-up measurement.
  function answerSketch(plan) {
    var qs = questions(plan);
    var parts = qs.map(function (q) {
      var cs = choicesOf(q).map(function (c) { return label(c.name); });
      return '    "' + label(q.id) + '": {\n' +
        '      "type": "choice",\n' +
        '      "choice": "<one of: ' + cs.join(', ') + '>",\n' +
        '      "confidence": <0 to 1, measured>,\n' +
        '      "probabilities": {' + cs.map(function (c) { return '"' + c + '": <p>'; }).join(', ') + '}\n' +
        '    }';
    });
    return '{\n' +
      '  "model": "' + plan.model + '",\n' +
      '  "answers": {\n' + parts.join(',\n') + '\n  },\n' +
      '  "usage": {"input_tokens": <n>, "output_tokens": <n>}\n' +
      '}\n';
  }

  function indent(text, n) {
    var pad = new Array(n + 1).join(' ');
    return String(text).replace(/\n$/, '').split('\n').map(function (l) { return pad + l; }).join('\n');
  }

  function deploy(plan) {
    var d = plan.deploy || {};
    return {
      namespace: d.namespace || 'agentgateway-system',
      gateway: d.gateway || 'model-gateway',
      profileName: d.profileName || 'jev-profile-v1',
      image: d.image || 'registry.example.com/jev-extproc:part5'
    };
  }

  // The profile, the adapter and its Service. Mirrors yaml/10-services.yaml in the
  // Part 5 guide, with the placeholders filled in from the plan.
  function manifests(plan) {
    var d = deploy(plan);
    return '' +
      'apiVersion: v1\n' +
      'kind: ConfigMap\n' +
      'metadata:\n' +
      '  name: ' + d.profileName + '\n' +
      '  namespace: ' + d.namespace + '\n' +
      'data:\n' +
      '  profile.json: |\n' +
      indent(profileJson(plan), 4) + '\n' +
      '---\n' +
      'apiVersion: apps/v1\n' +
      'kind: Deployment\n' +
      'metadata:\n' +
      '  name: jev-extproc\n' +
      '  namespace: ' + d.namespace + '\n' +
      'spec:\n' +
      '  replicas: 2\n' +
      '  selector:\n' +
      '    matchLabels: {app: jev-extproc}\n' +
      '  template:\n' +
      '    metadata:\n' +
      '      labels: {app: jev-extproc}\n' +
      '    spec:\n' +
      '      automountServiceAccountToken: false\n' +
      '      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}\n' +
      '      volumes:\n' +
      '        - name: profile\n' +
      '          configMap:\n' +
      '            name: ' + d.profileName + '   # a new name per version rolls the pods\n' +
      '      containers:\n' +
      '        - name: adapter\n' +
      '          image: ' + d.image + '\n' +
      '          env:\n' +
      '            - name: TYPESAFE_API_KEY\n' +
      '              valueFrom:\n' +
      '                secretKeyRef: {name: typesafe, key: TYPESAFE_API_KEY}\n' +
      '            - name: JEV_PROFILE_PATH\n' +
      '              value: /etc/jev/profile.json\n' +
      '          volumeMounts:\n' +
      '            - {name: profile, mountPath: /etc/jev, readOnly: true}\n' +
      '          ports: [{name: grpc, containerPort: 50051}]\n' +
      '          readinessProbe: {tcpSocket: {port: grpc}, initialDelaySeconds: 2}\n' +
      '          resources:\n' +
      '            requests: {cpu: 50m, memory: 32Mi}\n' +
      '            limits: {cpu: "1", memory: 128Mi}\n' +
      '          securityContext:\n' +
      '            allowPrivilegeEscalation: false\n' +
      '            readOnlyRootFilesystem: true\n' +
      '            capabilities: {drop: [ALL]}\n' +
      '---\n' +
      'apiVersion: v1\n' +
      'kind: Service\n' +
      'metadata:\n' +
      '  name: jev-extproc\n' +
      '  namespace: ' + d.namespace + '\n' +
      'spec:\n' +
      '  selector: {app: jev-extproc}\n' +
      '  ports: [{name: grpc, port: 50051, targetPort: grpc, appProtocol: kubernetes.io/h2c}]\n';
  }

  function secretCommand(plan) {
    var d = deploy(plan);
    return '# the key comes from your shell, not from a file in the repo\n' +
      'kubectl -n ' + d.namespace + ' create secret generic typesafe \\\n' +
      '  --from-literal=TYPESAFE_API_KEY="$TYPESAFE_API_KEY"\n';
  }

  function policy(plan, edition) {
    var d = deploy(plan);
    var ent = edition === 'enterprise';
    return '' +
      'apiVersion: ' + (ent ? 'enterpriseagentgateway.solo.io/v1alpha1' : 'agentgateway.dev/v1alpha1') + '\n' +
      'kind: ' + (ent ? 'EnterpriseAgentgatewayPolicy' : 'AgentgatewayPolicy') + '\n' +
      'metadata:\n' +
      '  name: jev-classify\n' +
      '  namespace: ' + d.namespace + '\n' +
      'spec:\n' +
      '  targetRefs:\n' +
      '    - {group: gateway.networking.k8s.io, kind: Gateway, name: ' + d.gateway + '}\n' +
      '  frontend:\n' +
      '    http:\n' +
      '      maxBufferSize: 32Ki\n' +
      '  traffic:\n' +
      '    phase: PreRouting          # classify before the route is chosen\n' +
      '    extProc:\n' +
      '      backendRef: {name: jev-extproc, port: 50051}\n' +
      '      failureMode: FailClosed  # no answer from Jev means no request\n' +
      '      processingOptions:\n' +
      '        requestHeaderMode: Send\n' +
      '        requestBodyMode: Buffered\n' +
      '        requestTrailerMode: Skip\n' +
      '        responseHeaderMode: Send\n' +
      '        responseBodyMode: None\n' +
      '        responseTrailerMode: Skip\n' +
      '        allowModeOverride: false\n';
  }

  root.JEV = {
    ENDPOINT: ENDPOINT,
    LABEL: LABEL,
    label: label,
    isSingle: isSingle,
    buildProfile: buildProfile,
    profileJson: profileJson,
    evaluate: evaluate,
    labels: labels,
    analyse: analyse,
    summarise: summarise,
    describe: describe,
    requestJson: requestJson,
    answerSketch: answerSketch,
    manifests: manifests,
    secretCommand: secretCommand,
    policy: policy,
    deploy: deploy
  };
})(typeof window !== 'undefined' ? window : globalThis);
