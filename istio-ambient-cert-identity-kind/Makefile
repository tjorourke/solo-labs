# Ambient cert-identity lab (petshop). Needs SOLO_ISTIO_LICENSE_KEY in the
# environment, or SECRETS_FILE pointing at a sourceable file that exports it,
# plus an authenticated gcloud (to pull the Solo Istio images).
#
# Quick path (this Makefile). The guided, show-every-command path is demo.ipynb.
#
#   make setup   SECRETS_FILE=~/path/to/secrets.sh   # kind + Solo ambient via Helm
#   make gloo-ui SECRETS_FILE=...                     # Gloo UI (Solo mgmt plane) + bg port-forward on a free local port
#   make deploy                                       # petshop: petstore + storefront + analytics + checkout(blue/green)
#   make svid                                         # each workload's SVID identity (shared SA = one cert)
#   make allow-storefront                             # L4 ALLOW storefront -> analytics/checkout denied
#   make allow-checkout                               # add sa/checkout -> BOTH checkout pods allowed (the gap)
#   make logs                                         # ztunnel identity-aware L4 access logs
#   make waypoint                                     # opt-in L7 waypoint on petstore (resets L4 policies)
#   make idp                                          # Keycloak IdP (users alice/user, bob/admin)
#   make jwt                                          # RequestAuthentication + claim-based L7 AuthorizationPolicy
#   make jwt-test                                     # matrix: no-token / alice / bob against GET and DELETE
#   make l7-routing                                   # petstore-v2 + HTTPRoute on the waypoint: 90/10 canary + x-beta header shift
#   make claims-enable                                # flip ENABLE_WORKLOAD_CLAIMS on ztunnel (per-pod certs; resets the L7 story)
#   make claims                                       # annotate blue=gold green=silver + CEL claim policy: blue 200, green denied
#   make clean                                        # delete the kind cluster
CTX ?= kind-cert-identity
NS  ?= petshop
KC  := http://keycloak.keycloak.svc.cluster.local:8080/realms/petshop/protocol/openid-connect/token

.PHONY: setup gloo-ui gloo-ui-forward deploy svid allow-storefront allow-checkout l4-surface l4-allow-warehouse logs waypoint idp jwt jwt-test l7-routing claims-enable claims clean

setup:
	./scripts/setup-cluster.sh

# Solo UI (Gloo Platform mgmt plane). Install BEFORE deploy to watch workloads
# appear. Ends with a backgrounded port-forward on a free local port (prints the URL).
gloo-ui:
	./scripts/gloo-ui.sh

gloo-ui-forward:
	./scripts/gloo-ui.sh forward

deploy:
	kubectl --context $(CTX) apply -f yaml/10-app/
	kubectl --context $(CTX) -n $(NS) rollout status deploy/petstore deploy/storefront deploy/analytics deploy/checkout-blue deploy/checkout-green --timeout=180s

svid:
	./scripts/svid.sh

allow-storefront:
	kubectl --context $(CTX) apply -f yaml/20-policy/10-allow-storefront.yaml
	@echo "storefront -> 200 ; analytics/checkout -> denied by ztunnel. Watch: make logs"

allow-checkout:
	kubectl --context $(CTX) apply -f yaml/20-policy/20-allow-checkout.yaml
	@echo "storefront + BOTH checkout pods -> 200 ; analytics still denied. blue and green share sa/checkout — make claims-enable closes that."

# a 2nd-namespace caller + a when(source.namespace) ALLOW + a DENY override
l4-surface:
	kubectl --context $(CTX) apply -f yaml/25-l4-surface/00-warehouse.yaml
	kubectl --context $(CTX) -n warehouse rollout status deploy/warehouse-svc --timeout=90s
	kubectl --context $(CTX) apply -f yaml/25-l4-surface/10-allow-petshop-namespace.yaml
	kubectl --context $(CTX) apply -f yaml/25-l4-surface/20-deny-analytics.yaml
	@echo "when(source.namespace): cross-ns warehouse-svc denied. DENY: analytics denied even though it's in petshop (DENY > ALLOW)."

# close the loop: widen the when-clause to admit warehouse — it flips to 200 and
# the warehouse namespace appears in the Gloo UI Graph (it now completes requests)
l4-allow-warehouse:
	kubectl --context $(CTX) apply -f yaml/25-l4-surface/30-allow-petshop-and-warehouse.yaml
	@echo "warehouse-svc -> 200 ; analytics still denied (DENY > ALLOW). Watch the warehouse namespace appear in the Graph (~30s)."

logs:
	./scripts/logs.sh

waypoint:
	kubectl --context $(CTX) -n $(NS) delete authorizationpolicy allow-storefront allow-checkout --ignore-not-found
	kubectl --context $(CTX) apply -f yaml/50-l7/10-waypoint.yaml
	kubectl --context $(CTX) label namespace $(NS) istio.io/use-waypoint=petstore-waypoint --overwrite
	kubectl --context $(CTX) -n $(NS) rollout status deploy/petstore-waypoint --timeout=150s

idp:
	kubectl --context $(CTX) apply -f yaml/40-idp/keycloak.yaml
	kubectl --context $(CTX) -n keycloak rollout status deploy/keycloak --timeout=240s

jwt:
	kubectl --context $(CTX) apply -f yaml/50-l7/20-jwt.yaml
	@echo "L7 JWT authz on the waypoint: any valid token may GET; only realm_access.roles=admin may DELETE."

# §11b: canary + header routing at the same waypoint (petstore-v2 + HTTPRoute)
l7-routing:
	kubectl --context $(CTX) apply -f yaml/50-l7/30-petstore-v2.yaml
	kubectl --context $(CTX) -n $(NS) rollout status deploy/petstore-v2 --timeout=120s
	kubectl --context $(CTX) apply -f yaml/50-l7/40-route-split.yaml
	@echo "90/10 canary petstore/petstore-v2 + x-beta:true -> v2. JWT policy still applies. Test: demo.ipynb §11b."

# matrix: no token / alice (user) / bob (admin), against GET and DELETE
jwt-test:
	@ALICE=$$(kubectl --context $(CTX) -n $(NS) exec deploy/storefront -- sh -c "curl -s -m10 -d grant_type=password -d client_id=petshop -d username=alice -d password=alice -d scope=openid $(KC)" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'); \
	 BOB=$$(kubectl --context $(CTX) -n $(NS) exec deploy/storefront -- sh -c "curl -s -m10 -d grant_type=password -d client_id=petshop -d username=bob -d password=bob -d scope=openid $(KC)" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'); \
	 c() { kubectl --context $(CTX) -n $(NS) exec deploy/storefront -- sh -c "$$1"; }; \
	 echo "no token    GET  /pets     -> $$(c "curl -s -o /dev/null -w '%{http_code}' -m5 http://petstore:8080/pets")"; \
	 echo "alice       GET  /pets     -> $$(c "curl -s -o /dev/null -w '%{http_code}' -m5 -H 'Authorization: Bearer $$ALICE' http://petstore:8080/pets")"; \
	 echo "alice(user) DELETE /pets/1 -> $$(c "curl -s -o /dev/null -w '%{http_code}' -m5 -X DELETE -H 'Authorization: Bearer $$ALICE' http://petstore:8080/pets/1")"; \
	 echo "bob(admin)  DELETE /pets/1 -> $$(c "curl -s -o /dev/null -w '%{http_code}' -m5 -X DELETE -H 'Authorization: Bearer $$BOB' http://petstore:8080/pets/1")"

# §13: turn on workload claims — ONE Helm value on ztunnel (per-pod certs).
# Resets the L7 story first (claims is pure L4).
claims-enable:
	./scripts/claims-enable.sh

# annotate the two checkout pods (the claim lands in each pod's own cert at
# issuance), then allow ONLY tier=gold at L4 with a CEL when-clause
claims:
	kubectl --context $(CTX) -n $(NS) patch deploy checkout-blue  -p '{"spec":{"template":{"metadata":{"annotations":{"solo.io.security-claims/tier":"gold"}}}}}'
	kubectl --context $(CTX) -n $(NS) patch deploy checkout-green -p '{"spec":{"template":{"metadata":{"annotations":{"solo.io.security-claims/tier":"silver"}}}}}'
	kubectl --context $(CTX) -n $(NS) rollout status deploy/checkout-blue deploy/checkout-green --timeout=120s
	kubectl --context $(CTX) apply -f yaml/60-claims/10-allow-gold-checkout.yaml
	@echo "checkout-blue (gold) -> 200 ; checkout-green (silver) -> denied by ztunnel, same sa/checkout. Watch: make logs"

clean:
	kind delete cluster --name cert-identity
