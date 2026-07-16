# Ambient port audit lab. Everything needs SOLO_ISTIO_LICENSE_KEY in the
# environment, or SECRETS_FILE pointing at a sourceable file that exports it:
#
#   make e2e SECRETS_FILE=~/path/to/secrets.sh       # the whole lab + assertions
#
# or step by step:
#
#   make setup SECRETS_FILE=...    # kind + Gloo Operator + ambient + JSON logs
#   make deploy                    # collector image + apps + policy + audit stack
#   make probe                     # hit the port the policy does not allow
#   make report                    # read report.json (used / unused / denied)
#   make remediate                 # apply the tightened policy the report justifies
#   make clean                     # delete the kind cluster
CTX ?= kind-port-audit

.PHONY: setup build deploy probe report remediate e2e clean

setup:
	./scripts/setup-cluster.sh

build:
	./scripts/build-collector.sh

deploy: build
	kubectl --context $(CTX) apply -f yaml/10-app/
	kubectl --context $(CTX) apply -f yaml/20-policy/
	kubectl --context $(CTX) apply -f yaml/30-audit/
	kubectl --context $(CTX) -n port-audit rollout status deploy/svc-a deploy/svc-b --timeout=180s
	kubectl --context $(CTX) -n port-audit-system rollout status ds/port-audit-collector --timeout=120s

probe:
	-kubectl --context $(CTX) -n port-audit exec deploy/svc-a -- curl -s --max-time 3 http://svc-b:7070/
	@echo "(the failed curl above is the point: 7070 is exposed but not in the AuthorizationPolicy)"

report:
	kubectl --context $(CTX) -n port-audit-system get cm port-audit-report -o jsonpath='{.data.report\.json}' | jq .

remediate:
	kubectl --context $(CTX) apply -f yaml/40-remediate/

e2e:
	./scripts/e2e.sh

clean:
	kind delete cluster --name port-audit
