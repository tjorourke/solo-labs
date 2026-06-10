# agentregistry-governance-kind

**AgentRegistry end to end, part 2.** Registry identity and access policies,
run on the part-1 cluster
([agentregistry-arctl-kind](../agentregistry-arctl-kind/)):

1. The AgentRegistry enterprise daemon moves off its embedded demo IdP and
   onto the **same Keycloak realm** part 1 used for kagent
   (`OIDC_ISSUER`, `RBAC_ROLE_CLAIM=groups`, `RBAC_SUPERUSER_ROLE=field-admin`).
2. With OIDC on, the catalog is **default-deny**: carol (group `field-admin`)
   is the superuser and sees everything; alice and bob see an empty catalog.
3. Two **AccessPolicies** carve out team lanes: alice (`field-fte`) gets
   read+publish on the summarizer stack and one named new skill; bob
   (`field-trial`) gets read on a single skill.
4. Every enforcement edge is shown live: filtered lists (absent, not denied),
   a forbidden by-name get, forbidden publishes outside the lane, and
   admin-only policy management.
5. alice publishes `release-notes-style` inside her lane, no admin involved,
   and bob still cannot see it.

Full write-up with captured output:
https://www.masterthemesh.com/solo/agentregistry-governance-kind/

## Run it

Part 1 must be up first (`../agentregistry-arctl-kind/scripts/quick.sh up`).

```bash
./scripts/quick.sh up        # registry -> Keycloak OIDC, policies, publish demo
./scripts/quick.sh status    # daemon env, policies, the three catalog views
./scripts/quick.sh down      # revert the daemon to the part-1 demo IdP

# poke at it as any identity
TOKEN=$(./scripts/tokens.sh bob)
arctl get skills --registry-token "$TOKEN"
```

## Layout

- `scripts/` — numbered steps plus `quick.sh` (up/down/status) and
  `tokens.sh` (mint alice/bob/carol Keycloak tokens).
- `yaml/policies/` — the two team AccessPolicies.
- `yaml/keycloak-nodeport.yaml` — exposes the part-1 Keycloak on the kind
  node so the daemon container can reach the issuer.
- `yaml/rogue-skill.yaml` — the publish that every policy should reject.
- `artifacts/release-notes-style/` — the skill alice publishes inside her lane.
