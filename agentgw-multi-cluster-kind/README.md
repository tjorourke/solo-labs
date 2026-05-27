# Solo AgentGateway Ambient Multicluster — Standup (kind)

Two kind clusters (`east-ag` + `west-ag`) on this Mac, peered over HBONE, with
Solo Istio Ambient + Solo Enterprise agentgateway. See `index.html` for the
full lab; this README covers the nightly-build switch on `scripts/quick.sh`.

## What `AGW_NIGHTLY=true` swaps under the hood

From `scripts/quick.sh:44-48`:

```bash
AGW_REGISTRY="oci://us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev/charts"
AGW_VERSION="v2026.5.0-beta.4-nightly-2026-05-15"
AGW_IMAGE_REGISTRY="us-central1-docker.pkg.dev/developers-369321/enterprise-agentgateway-dev"
```

First time it'll trigger interactive `gcloud auth login` if you haven't done
it; subsequent runs reuse the token.

## Mix-and-match overrides

If you want a different nightly tag than the one baked in, override
piece-by-piece (the env vars take precedence over the `AGW_NIGHTLY=true`
defaults):

```bash
AGW_NIGHTLY=true \
AGW_VERSION=v2026.5.X-nightly-YYYY-MM-DD \
  ./scripts/quick.sh

# Or fully manual (no NIGHTLY=true):
AGW_REGISTRY=oci://<host>/<path>/charts \
AGW_VERSION=<tag> \
AGW_IMAGE_REGISTRY=<host>/<path> \
  ./scripts/quick.sh
```

Run-time: ~15 min first time, ~5 min if images are already cached locally.
