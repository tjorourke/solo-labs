# The Part 8 agent. Java, on Google ADK, through agentgateway.
#
# No JDK or Maven on this machine: the container does both.
#
#   make show      the method that wires ADK to the gateway
#   make build     multi-stage docker build (maven -> jre)
#   make push      into the kind registry
#   make offline   fetch everything build needs while there is a network (base images,
#                  maven dependencies, the approved skill), so the demo builds with no wifi
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
# the FROM images, read off the Dockerfile so this list cannot drift from it
BASES   := $(shell sed -n 's/^FROM  *\([^ ]*\).*/\1/p' Dockerfile)

.PHONY: all show bases offline build push publish deploy ask logs clean skill.md

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
	@if [ -n "$(LOCAL_SKILL)" ]; then \
	  echo "== skill.md from the LOCAL working copy (LOCAL_SKILL=1) =="; \
	  SKILL=../skill/release-report/SKILL.md; \
	else \
	  echo "== the approved skill, from AgentRegistry =="; \
	  rm -rf .skill.new; \
	  if arctl pull skill release-report .skill.new >/dev/null 2>&1; then \
	    rm -rf .skill && mv .skill.new .skill; \
	    arctl get skill release-report -o yaml | sed -n 's/^ *subfolder: */   source: /p'; \
	    SKILL=.skill/SKILL.md; \
	  elif [ -s .skill/SKILL.md ]; then \
	    rm -rf .skill.new; \
	    echo "   no fresh pull (no network, or arctl not logged in): using the copy pulled $$(date -r .skill/SKILL.md '+%d %b %H:%M')"; \
	    SKILL=.skill/SKILL.md; \
	  else \
	    rm -rf .skill.new; \
	    echo "   ! arctl pull failed and nothing was pulled before. Is arctl logged in, and has"; \
	    echo "     the skill's source repository been updated? Using the local working copy."; \
	    SKILL=../skill/release-report/SKILL.md; \
	  fi; \
	fi; \
	awk '/^---$$/{c++;next} c>=2' "$$SKILL" > $@
	@echo "   skill.md is $$(wc -c < $@ | tr -d ' ') bytes"

## The images the Dockerfile builds FROM. Docker pulls one only when it is not already on
## this machine, so once both are here the build needs no network. Pull them here rather
## than leaving it to the build, so the failure at a venue with no wifi is one line that
## says what to do, not a buildkit trace. A prune removes them, which is how this bit.
bases:
	@for b in $(BASES); do \
	  docker image inspect $$b >/dev/null 2>&1 && continue; \
	  echo "== pulling $$b (not on this machine yet) =="; \
	  docker pull -q $$b >/dev/null || { \
	    echo "   ! could not pull $$b and it is not on this machine, so the build cannot start."; \
	    echo "     Run 'make offline' while you have a network."; \
	    exit 1; }; \
	done

## Everything the build step needs, fetched while there is still a network: the base
## images, the Maven dependencies (cached in the build layers, and the package step runs
## with -o so it never asks for more), the approved skill, and a check that the kind
## registry is up. After this, section 5 builds and pushes with the wifi off.
offline: bases build
	@docker ps --format '{{.Names}}' | grep -qx kind-registry \
	  || { echo "   ! the kind-registry container is not running, so 'make push' has nowhere to go"; exit 1; }
	@echo
	@echo "   the build needs no network now:"
	@for b in $(BASES); do printf '     %-36s on this machine\n' "$$b"; done
	@printf '     %-36s cached in the build layers\n' "maven dependencies"
	@printf '     %-36s .skill/, from the registry\n' "approved skill"
	@printf '     %-36s localhost:5001, a local container\n' "kind registry"
	@echo

build: bases skill.md
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

## Prompt it through kagent's OIDC-protected A2A endpoint, in a session the UI lists,
## with each tool call printed as it happens.
ask: PROMPT ?= Give me the release report for $(DEMO_REPO), all open pull requests.
ask:
	@AGENT=prtriagejava ../scripts/ask.sh "$(PROMPT)"

## What the agent itself logged, which is where the A2A turns show up.
logs:
	@$(KC) -n $(NS) logs deploy/prtriagejava --tail=40 2>/dev/null | grep -vE '^\[|SLF4J' || true

clean:
	-arctl delete deployment prtriagejava
	-arctl delete agent prtriagejava
	rm -rf skill.md .skill
