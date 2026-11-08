# Validation record

8 November 2026, Europe/London (GMT).

- Live requests at 10:45 GMT: both synthetic tickets passed through the Enterprise proxy with no client Authorization header. Raw response JSON and the first two-request metrics snapshot are in this directory.
- Repeated the documented curls and strengthened script test at 10:46 GMT. Three typed answers per ticket, queue billing/shipping, severity 0.99/0.0, human-review probability 1.0 for both. Token metric operation decisions, response model gpt-6-luna.
- Gateway Programmed=True; HTTPRoute Accepted=True and ResolvedRefs=True.
- Proxy image: us-docker.pkg.dev/solo-public/enterprise-agentgateway/agentgateway-enterprise:2026.10.2.
- Kubernetes: v1.35.0, kind v0.31.0. Gateway API v1.5.1.
- CRD fields: chart-rendered EnterpriseAgentgatewayBackend v2026.10.2 and live server dry-run. Three page manifests accepted, no uncovered kinds. The chart's route enum includes Decisions and SystemOne. v2026.10.0 rejects SystemOne, so both charts are pinned to v2026.10.2.
- Helm values: licensing.createSecret and licensing.secretName, read from the shipped chart and exercised live.
- The cached backend schema was regenerated using scripts/build-crd-cache-from-charts.py add/write helpers against the rendered v2026.10.2 CRD, preserving other cached kinds.
- Static: Bash syntax, Python compilation, page command-block Bash parsing, source embedding, metadata, prose, lab contract and shell lint. Local page and evidence downloads return HTTP 200.
- Collision control: quick.sh up refused the existing openai-decisions cluster without replacing it.
- Not run: fresh quick.sh up end to end (individual install commands were run, initially v2026.10.0 then upgraded); destructive teardown; SystemOne/chat-completions/passthrough calls; visual phone-width check of the whole page. No screenshot is used.
- No existing cluster was deleted or stopped. The new cluster remains running.
- Flow diagram (inline SVG on the lab page and the blog post): rendered with headless Chrome at 600 px and 344 px wide and checked by eye. No connector crosses a box and every label sits inside its box and the viewBox.
