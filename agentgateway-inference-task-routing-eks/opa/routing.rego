# The routing decision. The router has already said what kind of task this is; the gateway
# has already verified who is asking. This policy turns the two into where the request runs
# and which class of model answers, or refuses.
#
# Rule precedence, first match wins:
#   1. a secret in the prompt: block. Nothing that looks like a key leaves the caller.
#   2. a body the gateway could not forward whole: private, and a class that can read anything,
#      because none of the checks below have seen it.
#   3. the prompt carries the bank's own code, or came from an internal repository: private,
#      whatever the task said. A clean scan does not prove code is public; evidence that it
#      is ours overrides a generic classification.
#   3b. the caller's organisation classifies its data and the prompt carries a restricted
#      class: the class picks the pool, whatever the task said. Off for callers without
#      data_classes, so it changes nothing for anyone who has not opted in.
#   4. the task's preferred pool from the routing table, if the caller may use it.
#   5. otherwise private, if the caller may use private.
#   6. otherwise an error. There is no fall-through to the frontier.
#
# Then two adjustments, after the pool is settled, neither of which moves a request out of the
# private pool: a request carrying an image takes a class whose model can read one, and a
# request too long for the smaller window takes the class whose model holds it.
#
# Private is the default. The frontier is the exception, for clearly generic coding by
# callers the table permits, and nothing else.
package routing

import rego.v1

# The subject the gateway verified. agentgateway validates the JWT before calling extAuth
# and forwards the claims under the envoy.filters.http.jwt_authn metadata key, camel-cased
# by the OPA plugin's protojson decoding.
payload := input.attributes.metadataContext.filterMetadata["envoy.filters.http.jwt_authn"].jwt_payload

# Lab tokens put the employee in sub (bob, alice, dave). Agentdesktop tokens
# put a Keycloak UUID in sub and the login in email (bob@corp.example).
subject := payload.sub if object.get(data.users, payload.sub, false)

subject := split(payload.email, "@")[0] if {
	not object.get(data.users, payload.sub, false)
	is_string(payload.email)
	object.get(data.users, split(payload.email, "@")[0], false)
}

user := data.users[subject]

# The task label the router wrote on the classify listener.
task := input.attributes.request.http.headers["x-selected-model"]

table := data.routing.tasks[task]

# The prompt, for the data checks. The body is forwarded by the gateway (forwardBody).
body := json.unmarshal(input.attributes.request.http.body)

# The gateway forwards at most forwardBody.maxSize bytes and cuts the rest off, so a body over
# that limit reaches here as a fragment that will not parse and body is undefined. Every check
# below reads body, and an undefined body silently turns all of them off at once: the secret
# scan, the internal code check and the vision swap. That is not theoretical. An editor session
# with two screenshots pasted into it passed a megabyte, arrived truncated, and went to the
# coding model, which has no vision tower and refused the request with a 400 naming a model the
# caller never chose. Name the condition here and decide on it below rather than degrading.
body_readable if is_object(body)

# Every message, joined. The checks below read this rather than the last message alone,
# because an editor sends the question and the files it has open as separate parts of one
# request, and the intake hop lifts the question out into its own final message. Evidence
# anywhere in the request is evidence.
all_text := concat("\n", [t |
	some msg in body.messages
	t := message_text(msg)
])

# Message content is a string in the plain chat shape and a list of parts in the other one.
message_text(msg) := msg.content if is_string(msg.content)

message_text(msg) := concat(" ", [p.text |
	some p in msg.content
	is_string(p.text)
]) if not is_string(msg.content)

# --- data checks ---------------------------------------------------------------------------

# Things that look like credentials. Any hit blocks.
secret_patterns := [
	`AKIA[0-9A-Z]{16}`,
	`-----BEGIN [A-Z ]*PRIVATE KEY-----`,
	`sk-[A-Za-z0-9_-]{20,}`,
	`gh[pousr]_[A-Za-z0-9]{30,}`,
]

has_secret if {
	some p in secret_patterns
	regex.match(p, all_text)
}

# An image in the prompt. A client that never sent one has no list-shaped content at all.
# Both spellings, because the gateway serves both paths: a client on /v1/messages has its
# image converted to the chat-completions image_url part by the intake hop, and one that
# posts chat completions directly sends image_url itself. A request that arrives already
# in the Anthropic shape keeps type: image, so matching only one of them would let a
# screenshot through to a model that cannot read it.
image_part_types := {"image_url", "image", "input_image"}

has_image if {
	some msg in body.messages
	not is_string(msg.content)
	some p in msg.content
	p.type in image_part_types
}

# The same image one level down. A tool that reads a file returns its result as a part whose
# own content is a list, so a screenshot an agent opened for itself is nested inside a
# tool_result rather than sitting next to the question.
has_image if {
	some msg in body.messages
	not is_string(msg.content)
	some p in msg.content
	some q in p.content
	q.type in image_part_types
}

# Things that say this is our code: a package or service name from the internal list, or a
# provenance header from an application that knows which repository the code came from.
# The header can only make a request more private, never less, which is why a client
# supplied value is acceptable here.
has_internal_code if {
	some marker in data.dlp.internal_code_markers
	contains(all_text, marker)
}

has_internal_code if {
	repo := input.attributes.request.http.headers["x-source-repo"]
	some prefix in data.dlp.internal_repo_prefixes
	startswith(repo, prefix)
}

# Which class of the caller's own data this prompt carries. Only for a caller whose
# organisation has told us it classifies its data; for everyone else data_class is
# undefined and every rule below that reads it is off, so their decisions are unchanged.
#
# data.dlp.data_classes is an ordered list, most restricted first, and the first pattern
# that matches wins. The patterns are the same ones the Kernwerk DLP gateway routes on, so
# a prompt cannot be Class 3 on one page and Class 2 on another. Anything that matches
# nothing is the unrestricted class and this says nothing about it: the task table decides,
# exactly as it does today.
classifies_data if user.data_classes

# Attempts to talk the model out of its instructions, and a password typed into a
# prompt. Refused outright: nothing is redacted and nothing is forwarded, which is what
# separates a guardrail from the personal-data check.
#
# Decided here rather than as a prompt guard on the route. A guard's rejection is
# returned as if it were a model response, and the intake hop cannot convert that back
# for a client speaking the Messages API, so the caller sees a 502 instead of a refusal
# they can read. An extAuth denial carries its own status and arrives intact.
#
# Only for a caller whose organisation classifies its data, for the same reason the
# classes are: it is their policy, and nobody else's traffic changes.
jailbreak_patterns := [
	`(?i)ignore (all |any )?(previous|prior|your) (instructions|rules)`,
	`(?i)you (now )?have no (rules|restrictions)`,
	`(?i)(print|reveal|show) (me )?your system prompt`,
	`(?i)(password|passwort|kennwort)\s*[:=]\s*\S+`,
]

default has_jailbreak := false

has_jailbreak if {
	classifies_data
	body_readable
	some p in jailbreak_patterns
	regex.match(p, all_text)
}

matched_classes := [c |
	some c in data.dlp.data_classes
	regex.match(c.pattern, all_text)
]

data_class := matched_classes[0] if {
	classifies_data
	body_readable
	count(matched_classes) > 0
}

# --- the decision ---------------------------------------------------------------------------

may_use(pool) if pool in user.allowed_model_pools

# 2. the body arrived truncated. Nothing in it has been scanned, so it stays private whatever
# the table says, and it takes the class whose model reads images as well as text, because what
# could not be read might be one. A caller with no private pool gets the 403 below: an
# unscanned body is not something to send to the frontier.
routed := {"pool": "private", "class": data.routing.vision_fallback_class, "reason": sprintf("%s, body too large to inspect", [task])} if {
	not body_readable
	may_use("private")
}

# 3. our code: private, keep the task's class
routed := {"pool": "private", "class": table.class, "reason": sprintf("%s, internal code stays private", [task])} if {
	body_readable
	not has_secret
	has_internal_code
	may_use("private")
}

# 3b. the caller's data class, which outranks the task. A class only ever narrows where a
# request may run: the unrestricted class names no pool and leaves data_class undefined, so
# this rule and the one below are off and rule 4 decides as it always has.
routed := {"pool": data_class.pool, "class": table.class, "reason": sprintf("%s, %s", [task, data_class.why])} if {
	body_readable
	not has_secret
	not has_internal_code
	data_class
	may_use(data_class.pool)
}

# 3c. the class wants a pool this caller may not use. Private, which holds any class, rather
# than falling through to the table and sending restricted data somewhere wider.
routed := {
	"pool": "private",
	"class": table.class,
	"reason": sprintf("%s, %s, %s not permitted", [task, data_class.why, data_class.pool]),
} if {
	body_readable
	not has_secret
	not has_internal_code
	data_class
	not may_use(data_class.pool)
	may_use("private")
}

# 4. the table's preferred pool
routed := {"pool": table.pool, "class": table.class, "reason": task} if {
	body_readable
	not has_secret
	not has_internal_code
	not data_class
	may_use(table.pool)
}

# 5. the table wanted the frontier and the caller may not use it: private instead
routed := {"pool": "private", "class": table.class, "reason": sprintf("%s, frontier not permitted", [task])} if {
	body_readable
	not has_secret
	not has_internal_code
	not data_class
	table.pool != "private"
	not may_use(table.pool)
	may_use("private")
}

# 6. an image, and the class that was chosen cannot read one. The private coding model has no
# vision tower and vLLM refuses the whole request, so the caller meets a 400 naming a model they
# never chose. The class moves to one whose model can read the image and the reason says why.
# The frontier is untouched: it reads images, and this only ever moves a request between private
# models, never out of the private pool.
needs_vision_swap if {
	has_image
	routed.pool == "private"
	routed.class in data.routing.classes_without_vision
}

# 7. the request is longer than the smaller models can hold. The private coding model's window
# is 262,144 tokens and the other private models are 131,072, and vLLM refuses a request over
# its window rather than shortening it, so a long conversation on those models returns a 400
# quoting a limit the caller never chose.
#
# The gateway cannot count tokens, so the size of the forwarded body stands in for them, and the
# estimate is deliberately low: bytes_per_token is 3.5 against the 4.0 measured on this model's
# own tokenizer. max_tokens counts too, because vLLM checks the input and the requested output
# against one limit.
#
# An image takes precedence, and so does a body too large to inspect: no model both reads an
# image and holds the larger window, and rule 2 has already chosen for an unreadable body.
estimated_input_tokens := count(input.attributes.request.http.body) / data.routing.bytes_per_token

reserved_output := object.get(body, "max_tokens", 0) if body_readable

reserved_output := 0 if not body_readable

needs_long_context_swap if {
	estimated_input_tokens + reserved_output > data.routing.small_window_tokens
	body_readable
	not has_image
	routed.pool == "private"
	routed.class != data.routing.long_context_class
}

decision := routed if {
	not needs_vision_swap
	not needs_long_context_swap
}

decision := object.union(routed, {
	"class": data.routing.vision_fallback_class,
	"reason": sprintf("%s, image in prompt", [routed.reason]),
}) if needs_vision_swap

decision := object.union(routed, {
	"class": data.routing.long_context_class,
	"reason": sprintf("%s, too long for the smaller window", [routed.reason]),
}) if needs_long_context_swap

default result := {
	"allowed": false,
	"http_status": 403,
	"headers": {"content-type": "application/json"},
	"body": `{"error": {"type": "forbidden", "message": "no suitable permitted backend for this task"}}`,
}

# 1. a secret: block, with a reason the caller can act on
result := {
	"allowed": false,
	"http_status": 422,
	"headers": {"content-type": "application/json", "x-routing-reason": "blocked, credential in prompt"},
	"body": `{"error": {"type": "blocked", "message": "the prompt contains something that looks like a credential; remove it and try again"}}`,
} if {
	subject
	has_secret
}

# 1b. an attempt to override the model's instructions, or a password in the prompt
result := {
	"allowed": false,
	"http_status": 422,
	"headers": {"content-type": "application/json", "x-routing-reason": "blocked, tries to override the model or carries a password"},
	"body": `{"error": {"type": "blocked", "message": "Stopped at the Kernwerk gateway. This request tries to override the model's rules or carries a password, so no model received it."}}`,
} if {
	subject
	not has_secret
	has_jailbreak
}

# Allow, and write the decision where the route can match it. Any routing header the client
# sent is removed first, so where a request runs is decided here and nowhere else.
result := object.union(allowed_result, lane_header) if {
	not has_secret
	not has_jailbreak
	decision
}

allowed_result := {
	"allowed": true,
	"request_headers_to_remove": ["x-model-pool", "x-model-class", "x-routing-reason", "x-routing-user", "x-kernwerk-lane"],
	"headers": {
		"x-model-pool": decision.pool,
		"x-model-class": decision.class,
		"x-routing-reason": decision.reason,
		"x-routing-user": subject,
	},
	"response_headers_to_add": {
		"x-model-pool": decision.pool,
		"x-model-class": decision.class,
		"x-routing-reason": decision.reason,
	},
}

# The class this policy classified on, named so the decision can be read back. Written only
# for a caller whose data is classified, and only when this policy did the classifying, so a
# class on the page always means a class that was enforced: there is no way to show one
# beside a destination it did not allow. A caller's own x-kernwerk-lane is stripped above.
lane_header := {"headers": object.union(allowed_result.headers, {"x-kernwerk-lane": data_class.class})} if {
	data_class
}

lane_header := {"headers": object.union(allowed_result.headers, {"x-kernwerk-lane": "public"})} if {
	classifies_data
	body_readable
	not data_class
}

default lane_header := {}
