# TrustUs Bank refresh execution record

Refresh plan v2, 22 October 2026. The source plan was read from
`~/Downloads/trustusbank-refresh-plan-v2.md`.

## Phase 0: ground truth

**Executed.** The running CRDs were captured to `/tmp/trustusbank-crds.json`.
Confirmed `ModelConfig.spec.openAI.baseUrl` and `anthropic.baseUrl`, MCP
authorisation, fail-closed discovery, request-body CEL, auth header location,
AccessPolicy UserGroup/Agent subjects and explicit OAuth actor token types.
All four required licence/provider variables were present. No secret values
were included in the record. Solo Istio 1.30.3-solo charts and images were
available; no 1.30.4-solo tag was assumed.

## Phase 1: measured decisions

| Spike | Result | Decision |
| --- | --- | --- |
| S1: A2A bearer | **Executed.** ngrep on the customer specialist observed Carol's original Keycloak issuer/subject/groups, with no `act`. | Set `KAGENT_PROPAGATE_TOKEN=true`. A2A authorisation checks SPIFFE; MCP STS tokens contain one specialist actor. |
| S2: MCP layout | **Static comparison and executed selected path.** kagent's optional kmcp controller is disabled; adding three managed-server waypoints increases the pod count. The existing defence lab's Service/selector pattern was reused. | Three RemoteMCPServer resources reach the shared bank waypoint. The rejected managed-MCPServer variation was not deployed to the bank cluster. |
| S3: gateway exchange | **Executed.** Explicit actor/subject `tokenType: Jwt`, `mayAct: Required`, with and without inbound JWT validation returned HTTP 403. | Keep runtime-side STS exchange. No `unsupported token_type: N_A` result was seen on this retest. |
| S4: empty DENY | **Executed.** Empty subjects on named refunds-agent reported Applied but generated an **ALLOW** for the controller, not a universal DENY. | Kill switch lists Agent subjects explicitly. |
| S5: model route | **Executed.** Native Anthropic requests, including `/v1/messages`, failed the Completions parser. The OpenAI-compatible route to the Anthropic backend returned a real model reply. | ModelConfig provider OpenAI, Claude Haiku 4.5 through the gateway. Placeholder in agent pods. |
| S6: argument CEL | **Executed.** `mcp.tool.arguments` removed refund_payment from tools/list; direct calls returned Unknown tool. `json(request.body)` in traffic authorisation allowed £1,250 and refused £25,000 with 403. | Separate tool permission and amount policy. |
| S7: Solo Istio | **Executed.** Fresh `trustusbank-spike` cluster installed Solo Istio 1.30.3-solo and agentgateway v2026.10.0. Enterprise waypoint Programmed and its pod Ready. | Same Helm pattern used for the bank; default trust domain remains cluster.local. |

## Platform and runtime findings

- **Executed:** Carol's token contains customer-service and may_act names only
  customer-service-assistant/customer-agent. Keycloak's user-profile schema
  must admit the admin-managed bank_may_act attribute before writing it.
- **Executed:** 0.5.11 still needs skipOBO=true for runtime-side STS. Omitting it
  returned `obo token handler not ready` before the agent ran.
- **Executed:** generated UserGroup policies strip the bearer and include a
  controller discovery exception. Additional identity/Require policies are
  enforce the human's groups on controller-originated POSTs. A transformation
  restores the verified rawToken as the onward bearer, avoiding policy-order
  dependence. Carol receives an actual upstream 403.
- **Executed:** regular HTTP gateways and static host MCP backends lose the
  mesh identity needed for strict mTLS. The selectorless bank-gw Service and
  bank-waypoint, with MCP selectors and Service egress backends, preserve it.
- **Executed:** native `requireApproval` works on the top-level tool. Naming it
  refund_payment_with_approval avoided the model choosing ask_user instead.
  No custom agent image, runtime adapter or approval bridge is installed.
- **Executed:** the source kill switch appears in kagent and the translated
  policy is an EnterpriseAgentgatewayPolicy. Static agent-card discovery has
  a separate route; denying it made the parent fail before its model could
  explain the refused execution call. Keeping discovery available allows a
  normal assistant reply while the refunds POST is 403.

## Verification runs

1. The first full test reached the kill switch, then exposed the agent-card
   discovery failure. This was a gap in the new design, not an old lab bug.
   Added the card-only route; an actual blocked £900 turn then completed with
   the assistant explaining that refunds were unavailable.
2. The next run exposed a transient MCP discovery timeout during the small
   refund. The test correctly rejected the assistant's completed task because
   there was no bank receipt. A completed LLM turn alone is not a passing refund.
   The same issue appeared after the kill-switch round trip. Declining the
   optional GET stream did not resolve it and that attempted fix was removed.
   A Go-runtime spike exchanged a token but failed to propagate it to MCP; that
   experiment was reverted. The fourth run was invalidated by that live spike.
   The gateway now sets the provider's disable_parallel_tool_use flag, retaining
   all three specialist calls while scheduling tools sequentially.
3. **Executed: clean lifecycle passed.** Run `20261022-143532` completed in
   599 seconds: `upRc=0`, `verifyRc=0`, all 34 live checks passed, and teardown
   confirmed the cluster was absent. The run began after deleting the existing
   bank cluster, rather than relying on its earlier resources.
   Command:

   ```bash
   bash scripts/labs-e2e.sh --only trustusbank-agent-refund-kind --concurrency 1 \
     --gcloud-config default --secrets /Users/thomasorourke/code/solo/secrets/secrets-envs.sh
   ```

   The cold run exposed CoreDNS reload latency at the first OIDC discovery;
   it recovered within Helm's readiness window. The setup now explicitly
   rolls CoreDNS when adding the issuer rewrite and waits for readiness.
   The Python runtime is 0.10.3 with Google ADK 1.38.0 and MCP client 1.28.1;
   the MCP server SDK is separately pinned at 1.17.0.

4. **Executed: metadata checks.** The version recorder now reads explicitly
   sourced lab-local pins, instead of reporting no version pins for this lab.
   Its regression suite passes, including matrix precedence and ignored
   unused local files. `record-tested.py --from-results` recorded the 22 October
   Enterprise run. The public footer is generated from that record.

5. **Executed: presenter restored from empty state.** A second cold `up` and
   `test` finished at `2026-10-22T13:54:12Z`, with **37 checks passed**. This run
   included the explicit runtime pin, CoreDNS readiness, temperature zero,
   direct human-to-specialist refusal and the stronger L4 bypass assertion.
   That run's evidence contained 704 spans, including model usage and the denied
   hop. No tested credential values or human bearer tokens were found in span
   attributes.
   The cluster remains running with **36 pods** (including the test curl pod).
   This exceeds the plan's target of 32: per-agent waypoints were retained for
   native AccessPolicy generation and visibility. Optional extension pods were
   disabled. Removing the probe outside tests would leave 35 pods.

6. **Executed: final story and UI evidence.** UI inspection showed that the
   specialist sometimes escalated a large payment without calling the refund
   tool. The specialist prompt now delegates the decision to the gateway, and
   the test requires a real autonomous 403 in the same trace before approval.
   Read-only specialists are explicitly told never to ask for confirmation,
   avoiding a sub-agent approval pause. The final run at
   `2026-10-22T14:10:10Z` passed **38 checks**, with 708 spans, two denied-hop
   error spans and 240 usage-bearing spans. `evidence-sample.json` is the
   reduced capture from this final run.
   Browser validation also exercised a real approval card and clicked Approve
   as Bob, observed the completed receipt, and opened the source/translated
   kill-switch policies in both UIs. All three published images are captures
   of those product interfaces. The diagram was rendered and its text bounds
   and connector geometry checked. Desktop and 390px mobile layouts were checked.

## Publication checklist

- [x] Clean up, test and teardown through the harness
- [x] Final receipt, approval, negative-control and trace-redaction checks
- [x] Restore the running presenter cluster
- [x] Three UI evidence images and rendered diagram checked
- [x] Both site domains and the staff console checked
- [x] Version footer rebuilt from the actual run
- [ ] Commit, push and deployed asset checks
