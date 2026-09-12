# agent-authoring-hosting-kind

Part 6 of **Writing agents for kagent**. Host one agent so that every route out of it
ends at a gateway, and every route into it and into its tools is decided by identity:
a tool endpoint only that agent may call, an A2A path only one other agent may use, a
published route that needs a token, an egress policy that closes the rest, and an audit
that lists every way into the cluster's gateways.

[Browse the files in solo-labs](https://github.com/tjorourke/solo-labs/tree/main/agent-authoring-hosting-kind).
Clone `https://github.com/tjorourke/solo-labs.git` and run the commands below from
`agent-authoring-hosting-kind/`. Keep the lab directories together: this part sources
Part 1's `scripts/lib.sh` and applies its shared pieces first.

## Prerequisites

The same cluster as Parts 1 to 5, with Part 1's shared pieces applied (`quick.sh up` does
that for you):

- Solo Enterprise for kagent (tested on 0.4.3) with the `kagent-anthropic` key Secret
- Solo Enterprise for agentgateway (tested on v2026.8.2) with an ingress Gateway
  (default `ar-ingress` in `agentgateway-system`; override with `INGRESS_GATEWAY` and
  `INGRESS_GATEWAY_NS`)
- Istio ambient with the `kagent` namespace enrolled
- Keycloak as the OIDC issuer for the controller and the published route (discovered as
  in Part 1, or set `KEYCLOAK_URL`)
- A CNI that enforces `NetworkPolicy`; kind's default CNI does
- `kubectl`, `curl`, `python3`

## Bring it up

```bash
export CTX=kind-mesh1
./scripts/quick.sh up
```

`up` applies, in order: a waypoint in front of `api.anthropic.com` and a `ModelConfig`
whose base URL is that waypoint; a tool endpoint `contained-tools` with a policy naming
one agent identity; three declarative agents (`sre-contained`, `sre-caller`,
`sre-other`); an `AccessPolicy` allowing `sre-caller` alone to call `sre-contained`; a
`NetworkPolicy` allowing the three pods DNS, the kagent namespace, istiod and the collector and nothing else; and an `HTTPRoute` on
the ingress gateway with a Strict JWT policy.

## See it hold

```bash
./scripts/probe-as.sh sre-contained       # tools/list as that identity: four read tools
./scripts/probe-as.sh sre-other           # as an identity the policy does not name: none
./scripts/call-edge.sh                    # the published route: 401, then four tools with a token
./scripts/audit-endpoints.sh              # every way into the cluster's gateways, probed
../agent-authoring-contract-kind/scripts/ask.sh sre-caller "Which pods in sre-lab are unhealthy, and why?"
../agent-authoring-contract-kind/scripts/ask.sh sre-other  "Which pods in sre-lab are unhealthy, and why?"
```

`sre-caller` delegates to `sre-contained` over A2A and returns its report. `sre-other`,
wired to the same endpoint and the same agent, gets no tools and a 403 at
`sre-contained`'s waypoint.

## Waypoints

A waypoint belongs to a destination Service, not to a caller. Part 1's agents share one
waypoint in front of the shared tool endpoint and are told apart by identity in a single
policy; this part adds a dedicated tool waypoint for one agent, the agent's own waypoint
(from the `kagent.solo.io/waypoint` label) so a policy can name its callers, and a model
waypoint. The page has a table of the four and when a separate one is worth having.

## The checks

```bash
./scripts/check.sh      # or ./scripts/quick.sh test
```

1. Tools: `contained-tools` serves exactly four read tools to `sre-contained` and none to
   another identity; the direct route to `kagent-tools` is reset.
2. Egress: the contained pod cannot reach `api.anthropic.com` or `kagent-tools` itself
   and reaches its model through the waypoint.
3. A2A: `sre-caller`'s delegated turn is answered; `sre-other`'s call is refused.
4. Edge: the published route answers 401 with no token and serves the four read tools
   with one.
5. Audit: this part's published route is closed; every other published route is listed
   with its verdict.

## Files

| path | what |
|---|---|
| `yaml/10-model-egress.yaml` | Service + waypoint + backend to `api.anthropic.com`, HTTP/1.1 pinned |
| `yaml/20-model-config.yaml` | `ModelConfig` whose base URL is the model waypoint |
| `yaml/30-tools-endpoint.yaml` | the `contained-tools` endpoint and its catalogue entry |
| `yaml/40-tools-policy.yaml` | one identity, four read tools |
| `yaml/50-agent.yaml` | `sre-contained`, labelled for a waypoint of its own |
| `yaml/55-other-agent.yaml` | `sre-other`, wired to everything and named in no policy |
| `yaml/60-edge-route.yaml` | the published route, its Strict JWT policy and its tool policy |
| `yaml/70-egress-policy.yaml` | `NetworkPolicy`: DNS, the kagent namespace, istiod, the collector, nothing else |
| `yaml/80-tools-authz.yaml` | ztunnel refuses these agents' direct route to `kagent-tools` |
| `yaml/90-a2a.yaml` | `sre-caller` and the `AccessPolicy` that lets it, alone, call `sre-contained` |
| `scripts/check.sh` | the five checks |
| `scripts/audit-endpoints.sh` | waypoints, exposed Services, published routes probed without a token |

## Teardown

```bash
./scripts/quick.sh teardown     # this part's objects; Part 1's shared pieces stay
```
