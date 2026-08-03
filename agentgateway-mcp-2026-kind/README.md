# MCP 2026-07-28 on the wire, live: MRTR and Tasks through agentgateway v1.4.1

A kind lab for the final MCP 2026-07-28 specification through agentgateway
v1.4.1 (OSS), declared entirely through Kubernetes CRDs: the control plane is
installed with helm (chart 1.4.1) and the gateway is a `Gateway` +
`AgentgatewayParameters` + `AgentgatewayBackend` + `HTTPRoute`.
A single-file, stdlib-only Python MCP
server (`src/server.py`) answers `server/discover`, pauses `cleanup_files`
with an MRTR `input_required` result carrying an HMAC-protected
`requestState`, and runs `run_pipeline` as an MCP Task
(`io.modelcontextprotocol/tasks`) with a human deploy-approval gate.
Everything is driven with curl so every payload is visible on the wire.

Highlights:

- `Mcp-Method`/`Mcp-Name` header enforcement: the gateway rejects
  header/body mismatches with `-32020` before anything reaches a backend.
- The MRTR retry completes after the entire server deployment is replaced;
  the pod that asked the question no longer exists.
- A tampered `requestState` is rejected at HMAC verification.
- The paused task surfaces the same elicitation object MRTR delivers
  inline; the client answers via `tasks/update`.
- The gateway rewrites `ttlMs`/`cacheScope` on proxied results to
  non-cacheable, its deliberate conservative caching policy.

## Run it

```bash
./scripts/up.sh      # kind cluster + ops-mcp + agentgateway v1.4.1
# follow the lab page for the curl flows
./scripts/down.sh
```

`scripts/quick.sh` runs the whole flow non-interactively (bring-up, discover,
MRTR pause/answer, task create/approve/complete, teardown) and prints PASS.

The full walkthrough with captured payloads is the lab page
(`index.html`, published on the site), and the background is the blog post
"MCP went stateless: the 2026-07-28 spec on the wire".
