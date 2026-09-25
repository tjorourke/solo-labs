# vLLM Semantic Router and Jev configuration wizard

Answer a few questions about the kinds of request you want to tell apart, and this
writes the classifier's configuration for you: the vLLM Semantic Router values file,
or the profile, manifests and gateway policy for a Jev ExtProc adapter. Then it checks that file for the mistake that
is hardest to catch by eye: a rule that reads perfectly well and can never fire, because
a broader one above it always matches first.

Hosted copy: **https://mastertheagent.com/solo/vsr-config-builder/**

It is a static page. No backend, no database, no build step, no account, and nothing is
sent anywhere: the questions, the generated YAML and all of the checks run in your
browser. That is why self-hosting it is six files and an nginx image.

---

## Run it

Pick one. All three end up on `http://localhost:8080`.

### 1. No container at all

Any static file server will do. From this directory:

```bash
python3 -m http.server 8080
```

Then open **http://localhost:8080/standalone.html**.

That is the whole thing. If you only want to use the wizard, stop here.

### 2. Docker

From this directory (not from `selfhost/`, the build context is the parent):

```bash
docker build -f selfhost/Dockerfile -t vsr-config-wizard .
docker run --rm -p 8080:8080 vsr-config-wizard
```

Open **http://localhost:8080**.

Or with compose, which adds the read-only root filesystem and drops capabilities:

```bash
docker compose -f selfhost/docker-compose.yml up --build
```

### 3. Kubernetes

Build and push the image somewhere your cluster can pull from, set that image in
`selfhost/k8s.yaml`, then:

```bash
kubectl apply -f selfhost/k8s.yaml
kubectl -n vsr-tools rollout status deploy/vsr-config-wizard
kubectl -n vsr-tools port-forward svc/vsr-config-wizard 8080:80
```

Open **http://localhost:8080**.

There is no published image on purpose. It is nginx plus six files you can read, so
build it yourself and you know exactly what is in it.

The namespace is labelled `pod-security.kubernetes.io/enforce: restricted`, and the
image is built to satisfy that: it listens on 8080, runs as uid 101, wants no
capabilities and runs with a read-only root filesystem.

---

## Put it behind a hostname

The page has no server side, so anything that serves static files in front of it works.
A Gateway API route, if you are already running one:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vsr-config-wizard
  namespace: vsr-tools
spec:
  parentRefs:
    - name: my-gateway
      namespace: my-gateway-namespace
  hostnames:
    - vsr-wizard.internal.example.com
  rules:
    - backendRefs:
        - name: vsr-config-wizard
          port: 80
```

---

## What it does, and what it cannot

**It does** ask what categories you are routing into, how each one is recognised, which
of them get confused with each other, and what order to try them in. Then it writes the
Helm values file and runs the checks the router's own validator does not make:

| Check | Why the validator misses it |
|---|---|
| A decision that can never win | Every reference is valid. It simply sits below a decision that asks for less, so that one always matches first. |
| A decision with no conditions | Structurally fine. Describes nothing. |
| A label nothing routes to | The label exists, so nothing is technically wrong. |
| Two decisions sharing a priority | Legal. Which of them wins is not defined. |
| The same phrase in both halves of a comparison | The two sides cancel out and the comparison stops discriminating. |
| Comparisons and words that no decision uses | Dead weight, and usually a rename that was not finished. |

**It cannot** tell you whether your example prompts actually separate your categories.
That needs the router's embedding model, which is a 768-dimension classifier on a volume
in your cluster, not something that runs in a browser.

For that part there is `tools/vsr-workbench` in
[solo-demos](https://github.com/tjorourke/solo-labs). It runs a labelled corpus through a
live router and gives you a confusion matrix and the signals behind every miss, and it
can do that for a config you have not deployed yet. This wizard writes the file; the
workbench tells you whether the file was right.

---

## The Jev option

The first step asks which classifier the config is for. Pick **Jev** and the questions
change: Jev is TypeSafe's hosted classifier, so there are no signals to tune. You write
Choice questions with a description per answer, decide which label each answer (or each
combination of answers) produces, and set how confident Jev has to be before an answer
counts. The review step writes:

| Output | What it is |
|---|---|
| `profile.json` | The ExtProc adapter's profile: the questions it sends to Jev, the thresholds, the fallback and the rules |
| `jev-extproc.yaml` | The profile ConfigMap, the adapter Deployment and its Service |
| The gateway policy | A `PreRouting` `extProc` policy, for OSS or Enterprise agentgateway |

It checks for rules that can never match because a rule above asks for less, rules and
questions that refer to names that do not exist, answers with no description, and the
adapter's own limits. A profile with one question, where every answer is its own label,
runs on the reference adapter in the
[Part 5 guide](https://mastertheagent.com/solo/agentgateway-inference-jev-routing-eks/)
as it is. Several questions combined by rules need the rules extension that guide
describes.

Link straight to it with `?engine=jev`.

---

## Use the generated file

```bash
helm upgrade --install semantic-router \
  oci://ghcr.io/vllm-project/semantic-router/charts/semantic-router \
  -n agentgateway-system --create-namespace \
  -f values-semantic-router.yaml
```

The chart stamps a checksum on the pod template, so every config change replaces the
pod. There is no hot reload: the config is mounted from a ConfigMap with a `subPath`,
and kubelet never updates a `subPath` mount. Budget a restart per edit, and check the
version your chart expects before pointing it at a new file.

---

## The files

| File | What it is |
|---|---|
| `standalone.html` | The page, with its own styling. This is the one the container serves. |
| `index.html` | The same wizard, but expecting the website's stylesheet around it. Used by the hosted copy only. |
| `vsr-core.js` | Router config generation, the YAML writer, and every check. No DOM, no network. |
| `jev-core.js` | The Jev side: adapter profile, manifests, gateway policy and the rule checks. No DOM, no network. |
| `presets.js` | Worked starting points and the catalogue of ready-made example prompts. |
| `wizard.js` | The question flow. |
| `wizard.css` | Styling, all of it scoped under `.vw`. |
| `selfhost/` | Dockerfile, nginx config, compose file, Kubernetes manifests. |

`vsr-core.js` is a port of `vsrlib/analyse.py` from the workbench. They are kept in step
by `tools/vsr-workbench/test_core_parity.py`, which runs 32 deliberately broken configs
through both and fails if a single finding differs, so the answer you get here is the
answer the Python tool would give.

---

## Where this came from

The routing labs on [mastertheagent.com](https://mastertheagent.com/solo/), in
particular [prompt-aware model routing, part
4](https://mastertheagent.com/solo/agentgateway-inference-task-routing-eks/), where the
router's config is the hardest part of the lab and almost none of the difficulty is the
YAML.

This directory is mirrored from the `solo-demos` repository. Raise anything you find
against the hosted page and it will reach the same place.
