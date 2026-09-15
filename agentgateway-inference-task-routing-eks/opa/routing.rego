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

# The prompt, for the data checks. The body is forwarded by the gateway (forwardBody) and
# the last user message is the one the router classified.
body := json.unmarshal(input.attributes.request.http.body)

last_user_message := m if {
	msgs := [msg.content | some msg in body.messages; msg.role == "user"]
	count(msgs) > 0
	m := msgs[count(msgs) - 1]
}

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
	regex.match(p, last_user_message)
}

# Things that say this is our code: a package or service name from the internal list, or a
# provenance header from an application that knows which repository the code came from.
# The header can only make a request more private, never less, which is why a client
# supplied value is acceptable here.
has_internal_code if {
	some marker in data.dlp.internal_code_markers
	contains(last_user_message, marker)
}

has_internal_code if {
	repo := input.attributes.request.http.headers["x-source-repo"]
	some prefix in data.dlp.internal_repo_prefixes
	startswith(repo, prefix)
}

# --- the decision ---------------------------------------------------------------------------

may_use(pool) if pool in user.allowed_model_pools

# 2. our code: private, keep the task's class
decision := {"pool": "private", "class": table.class, "reason": sprintf("%s, internal code stays private", [task])} if {
	not has_secret
	has_internal_code
	may_use("private")
}

# 3. the table's preferred pool
decision := {"pool": table.pool, "class": table.class, "reason": task} if {
	not has_secret
	not has_internal_code
	may_use(table.pool)
}

# 4. the table wanted the frontier and the caller may not use it: private instead
decision := {"pool": "private", "class": table.class, "reason": sprintf("%s, frontier not permitted", [task])} if {
	not has_secret
	not has_internal_code
	table.pool != "private"
	not may_use(table.pool)
	may_use("private")
}

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
