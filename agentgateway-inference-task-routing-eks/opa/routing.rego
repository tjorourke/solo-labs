# The routing decision. The router has already said what kind of task this is; the gateway
# has already verified who is asking. This policy turns the two into where the request runs
# and which class of model answers, or refuses.
#
# Rule precedence, first match wins:
#   1. a secret in the prompt: block. Nothing that looks like a key leaves the caller.
#   2. the prompt carries the bank's own code, or came from an internal repository: private,
#      whatever the task said. A clean scan does not prove code is public; evidence that it
#      is ours overrides a generic classification.
#   3. the task's preferred pool from the routing table, if the caller may use it.
#   4. otherwise private, if the caller may use private.
#   5. otherwise an error. There is no fall-through to the frontier.
#
# Then one adjustment, after the pool is settled: a private request carrying an image moves to
# a class whose model can read one. It never changes the pool.
#
# Private is the default. The frontier is the exception, for clearly generic coding by
# callers the table permits, and nothing else.
package routing

import rego.v1

# The subject the gateway verified. agentgateway validates the JWT before calling extAuth
# and forwards the claims under the envoy.filters.http.jwt_authn metadata key, camel-cased
# by the OPA plugin's protojson decoding.
subject := input.attributes.metadataContext.filterMetadata["envoy.filters.http.jwt_authn"].jwt_payload.sub

user := data.users[subject]

# The task label the router wrote on the first hop.
task := input.attributes.request.http.headers["x-selected-model"]

table := data.routing.tasks[task]

# The prompt, for the data checks. The body is forwarded by the gateway (forwardBody).
body := json.unmarshal(input.attributes.request.http.body)

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

# --- the decision ---------------------------------------------------------------------------

may_use(pool) if pool in user.allowed_model_pools

# 2. our code: private, keep the task's class
routed := {"pool": "private", "class": table.class, "reason": sprintf("%s, internal code stays private", [task])} if {
	not has_secret
	has_internal_code
	may_use("private")
}

# 3. the table's preferred pool
routed := {"pool": table.pool, "class": table.class, "reason": task} if {
	not has_secret
	not has_internal_code
	may_use(table.pool)
}

# 4. the table wanted the frontier and the caller may not use it: private instead
routed := {"pool": "private", "class": table.class, "reason": sprintf("%s, frontier not permitted", [task])} if {
	not has_secret
	not has_internal_code
	table.pool != "private"
	not may_use(table.pool)
	may_use("private")
}

# 5. an image, and the class that was chosen cannot read one. The private coding model has no
# vision tower and vLLM refuses the whole request, so the caller meets a 400 naming a model they
# never chose. The class moves to one whose model can read the image and the reason says why.
# The frontier is untouched: it reads images, and this only ever moves a request between private
# models, never out of the private pool.
needs_vision_swap if {
	has_image
	routed.pool == "private"
	routed.class in data.routing.classes_without_vision
}

decision := routed if not needs_vision_swap

decision := object.union(routed, {
	"class": data.routing.vision_fallback_class,
	"reason": sprintf("%s, image in prompt", [routed.reason]),
}) if needs_vision_swap

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

# Allow, and write the decision where the route can match it. Any routing header the client
# sent is removed first, so where a request runs is decided here and nowhere else.
result := {
	"allowed": true,
	"request_headers_to_remove": ["x-model-pool", "x-model-class", "x-routing-reason", "x-routing-user"],
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
} if {
	not has_secret
	decision
}
