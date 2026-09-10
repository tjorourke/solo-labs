# The Java agent: build, publish, run. No JDK or Maven needed on this machine, the
# container does both.
#
#   make show      the six lines that wire ADK to the gateway
#   make build     multi-stage docker build (maven -> jre)
#   make push      into the kind registry
#   make publish   register it in AgentRegistry with arctl
#   make run       run it in the cluster as a Job and follow the output
#   make all       build, push, publish, run
#   make clean     remove the Job and the catalogue entry

IMAGE   ?= localhost:5001/prtriage-java:latest
CTX     ?= kind-mesh1
NS      ?= kagent
SRC     := src/main/java/io/solo/demo/ReleaseReport.java
JOBYAML := ../yaml/50-java-agent-job.yaml
KC      := kubectl --context $(CTX)

.PHONY: all show build push publish run logs clean

all: build push publish run

## the part worth putting on a screen
show:
	@echo
	@echo "  ── the whole integration, from ReleaseReport.java ──"
	@echo
	@sed -n '/private static LlmAgent agent(/,/^  }/p' $(SRC) | sed 's/^/  /'
	@echo
	@echo "  No GitHub token. No tool list. No policy. The gateway owns all three."
	@echo

## The approved skill has exactly one source, so it cannot drift between the two
## agents. The docker build context cannot reach outside this directory, so we copy it
## in here at build time rather than keeping a second edited copy under source control.
skill.md: ../skill/release-report/SKILL.md
	@awk '/^---$$/{c++;next} c>=2' $< > $@
	@echo "== skill.md regenerated from the approved skill ($$(wc -c < $@ | tr -d " ") bytes) =="

build: skill.md
	@echo "== building $(IMAGE) (maven runs inside the image) =="
	docker build -t $(IMAGE) .

push:
	@echo "== pushing to the kind registry =="
	docker push -q $(IMAGE)

## register it in the catalogue. Same command as the Python agent.
publish:
	@echo "== publishing to AgentRegistry =="
	arctl apply -f agent.yaml
	@arctl get agents

## Run it as a Job. A DEPLOYED kagent agent has to serve A2A on
## /.well-known/agent-card.json, and this is a batch program, so a Job is the honest
## shape for it. Everything about the gateway is identical either way.
run:
	@echo "== running in-cluster =="
	-$(KC) -n $(NS) delete job prtriage-java --ignore-not-found
	$(KC) apply -f $(JOBYAML)
	@echo "== waiting =="
	@$(KC) -n $(NS) wait --for=condition=complete job/prtriage-java --timeout=300s \
	  || $(KC) -n $(NS) wait --for=condition=failed job/prtriage-java --timeout=10s
	@$(MAKE) --no-print-directory logs

logs:
	@$(KC) -n $(NS) logs job/prtriage-java 2>/dev/null | grep -vE '^\[main\] INFO|^SLF4J' || true

clean:
	-$(KC) -n $(NS) delete job prtriage-java --ignore-not-found
	-arctl delete agent prtriagejava
	rm -f skill.md
