# The Part 8 agent. Java, on Google ADK, through agentgateway.
#
# No JDK or Maven on this machine: the container does both.
#
#   make show      the method that wires ADK to the gateway
#   make build     multi-stage docker build (maven -> jre)
#   make push      into the kind registry
#   make publish   register it in AgentRegistry with arctl
#   make deploy    deploy it onto kagent as a pod, via AgentRegistry
#   make ask       prompt it through kagent's A2A endpoint
#   make all       build, push, publish, deploy, ask
#   make logs      what the agent logged, where the A2A turns show up
#   make clean     remove the deployment and the catalogue entry

CLUSTER ?= mesh1
IMAGE   ?= localhost:5001/prtriage-java:latest
DEMO_REPO ?= tjorourke/kagent
CTX     ?= kind-mesh1
NS      ?= kagent
SRC     := src/main/java/io/solo/demo/ReleaseReport.java
KC      := kubectl --context $(CTX)

.PHONY: all show build push publish deploy ask logs clean skill.md

all: build push publish deploy ask

## the part worth putting on a screen
show:
	@echo
	@echo "  ── the whole integration, from ReleaseReport.java ──"
	@echo
	@sed -n '/private static LlmAgent agent(/,/^  }/p' $(SRC) | sed 's/^/  /'
	@echo
	@echo "  No GitHub token. No tool list. No policy. The gateway owns all three."
	@echo

## The approved skill comes FROM THE REGISTRY, the same way demo 4 pulls it. That is
## the point of having a registry: the agent is built against a pinned, versioned
## record rather than whatever happens to be in the working tree.
##
## LOCAL_SKILL=1 uses the working copy instead, which is what you want while editing
## the skill, since a pull would fetch the last version that reached the mirror.
skill.md:
	@if [ -n "$(LOCAL_SKILL)" ]; then 	  echo "== skill.md from the LOCAL working copy (LOCAL_SKILL=1) =="; 	  awk '/^---$$/{c++;next} c>=2' ../skill/release-report/SKILL.md > $@; 	else 	  echo "== pulling the approved skill from AgentRegistry =="; 	  rm -rf .skill; 	  arctl pull skill release-report .skill >/dev/null || { 	    echo "   ! arctl pull failed. Is arctl logged in, and has the skill's source"; 	    echo "     repository been updated? Falling back to the local copy."; 	    awk '/^---$$/{c++;next} c>=2' ../skill/release-report/SKILL.md > $@; 	    exit 0; }; 	  awk '/^---$$/{c++;next} c>=2' .skill/SKILL.md > $@; 	  arctl get skill release-report -o yaml | sed -n 's/^ *subfolder: */   source: /p'; 	fi
	@echo "   skill.md is $$(wc -c < $@ | tr -d ' ') bytes"

build: skill.md
	@echo "== building $(IMAGE) (maven runs inside the image) =="
	@# --progress=quiet: buildkit's default output is forty lines of layer chatter,
	@# which is unreadable on a projector. The summary below says the same thing.
	docker build --progress=quiet -t $(IMAGE) .

push:
	@echo "== pushing to the kind registry =="
	docker push -q $(IMAGE)
	@# The tag is :latest and the pods pull IfNotPresent, so a node that already has a
	@# :latest keeps serving it and a restart quietly runs the PREVIOUS build. Drop it
	@# from every node, or the next step demonstrates yesterday's agent.
	@for n in $$(kind get nodes --name $(CLUSTER) 2>/dev/null); do \
	   docker exec $$n crictl rmi $(IMAGE) >/dev/null 2>&1 || true; \
	 done; echo "   cleared the cached image from the cluster nodes"

## register it in the catalogue. Same command as the Python agent.
publish:
	@echo "== publishing to AgentRegistry =="
	arctl apply -f agent.yaml
	@arctl get agents

## Deploy it onto kagent as a long-lived pod, the same shape as the Python agent.
## SERVE=true starts the A2A server so the readiness probe on
## /.well-known/agent-card.json passes and the controller can reach it.
deploy: publish
	@echo "== deploying onto kagent via AgentRegistry =="
	arctl apply -f ../yaml/60-java-deploy-kagent.yaml
	@until $(KC) -n $(NS) get deploy/prtriagejava >/dev/null 2>&1; do sleep 2; done
	@$(KC) -n $(NS) rollout status deploy/prtriagejava --timeout=240s
	@# The Deployment rolling out is not the same as kagent calling the agent Ready:
	@# the controller has to fetch the agent card first. Wait for the real thing, or
	@# the next line prints READY=False and looks like a failure.
	@$(KC) -n $(NS) wait --for=condition=Ready agent/prtriagejava --timeout=120s >/dev/null
	@$(KC) -n $(NS) get agent prtriagejava
	@printf '   running image  %s\n' "$$($(KC) -n $(NS) get pod -l app.kubernetes.io/name=prtriagejava \
	   -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')"

## Prompt it through kagent's OIDC-protected A2A endpoint. ask.sh mints the OIDC token
## from inside a pod and needs python3 to do it, which this image does not have, so it
## finds one in the namespace that does. Set EXEC_FROM to force a particular pod.
ask: PROMPT ?= Give me the release report for $(DEMO_REPO), all open pull requests.
ask:
	@cd ../../../demo-scripts/agentregistry && AGENT_PREFIX=prtriagejava \
	  $(if $(EXEC_FROM),EXEC_FROM=$(EXEC_FROM),) ./scripts/ask.sh "$(PROMPT)"

## What the agent itself logged, which is where the A2A turns show up.
logs:
	@$(KC) -n $(NS) logs deploy/prtriagejava --tail=40 2>/dev/null | grep -vE '^\[|SLF4J' || true

clean:
	-arctl delete deployment prtriagejava
	-arctl delete agent prtriagejava
	rm -rf skill.md .skill
