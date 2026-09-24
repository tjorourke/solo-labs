# Business decisions only. AGW validates JWTs, sets routing headers and enforces
# the returned status. Membership comes from the IdP, never a user list here.
package routing

import rego.v1

payload := input.attributes.metadataContext.filterMetadata["envoy.filters.http.jwt_authn"].jwt_payload
http := input.attributes.request.http

# Agentdesktop carries verified IdP claims inside its own signed token.
identity := payload.idp if payload.iss == "agentdesktop-controller"
identity := payload if payload.iss != "agentdesktop-controller"

groups := identity.groups if is_array(identity.groups)
else := []

roles := [data.roles[group] | some group in groups; is_string(group)]
known_caller if {
	is_string(payload.sub)
	payload.sub != ""
	count(roles) > 0
}

# The readable name is for logs only, never an entitlement lookup key.
subject := split(identity.email, "@")[0] if {
	payload.iss == "agentdesktop-controller"
	is_string(identity.email)
} else := object.get(payload, "sub", "")

may_use(pool) if {
	known_caller
	some role in roles
	pool in role.allowed_model_pools
}

classifies_data if {
	some role in roles
	role.data_classes == true
}

task := object.get(http.headers, "x-selected-model", "")
table := data.routing.tasks[task]
body := json.unmarshal(http.body)
body_readable if is_object(body)

# Inspect every message, including string content and text parts in tool messages.
message_text(msg) := msg.content if is_string(msg.content)
else := concat(" ", [p.text | some p in msg.content; is_string(p.text)])
all_text := concat("\n", [message_text(msg) | some msg in body.messages])

has_secret if {
	some pattern in [
		`AKIA[0-9A-Z]{16}`,
		`-----BEGIN [A-Z ]*PRIVATE KEY-----`,
		`sk-[A-Za-z0-9_-]{20,}`,
		`gh[pousr]_[A-Za-z0-9]{30,}`,
	]
	regex.match(pattern, all_text)
}

has_jailbreak if {
	classifies_data
	body_readable
	some pattern in [
		`(?i)ignore (all |any )?(previous|prior|your) (instructions|rules)`,
		`(?i)you (now )?have no (rules|restrictions)`,
		`(?i)(print|reveal|show) (me )?your system prompt`,
		`(?i)(password|passwort|kennwort)\s*[:=]\s*\S+`,
	]
	regex.match(pattern, all_text)
}

has_internal_code if {
	some marker in data.dlp.internal_code_markers
	contains(all_text, marker)
}
has_internal_code if {
	some prefix in data.dlp.internal_repo_prefixes
	startswith(http.headers["x-source-repo"], prefix)
}

# Class 3 precedes Class 2. No match leaves the task's preferred pool in place.
data_class := matches[0] if {
	classifies_data
	body_readable
	matches := [c | some c in data.dlp.data_classes; regex.match(c.pattern, all_text)]
	count(matches) > 0
}

# Select a permitted pool. Ordered branches make the precedence explicit.
routed := {"pool": "private", "class": data.routing.vision_fallback_class,
	"reason": sprintf("%s, body too large to inspect", [task])} if {
	not body_readable
	may_use("private")
} else := {"pool": "private", "class": table.class,
	"reason": sprintf("%s, internal code stays private", [task])} if {
	body_readable
	has_internal_code
	may_use("private")
} else := {"pool": data_class.pool, "class": table.class,
	"reason": sprintf("%s, %s", [task, data_class.why])} if {
	body_readable
	not has_internal_code
	may_use(data_class.pool)
} else := {"pool": "private", "class": table.class,
	"reason": sprintf("%s, %s, %s not permitted", [task, data_class.why, data_class.pool])} if {
	body_readable
	not has_internal_code
	data_class
	not may_use(data_class.pool)
	may_use("private")
} else := {"pool": table.pool, "class": table.class, "reason": task} if {
	body_readable
	not has_internal_code
	not data_class
	may_use(table.pool)
} else := {"pool": "private", "class": table.class,
	"reason": sprintf("%s, frontier not permitted", [task])} if {
	body_readable
	not has_internal_code
	not data_class
	not may_use(table.pool)
	may_use("private")
}

image_types := {"image_url", "image", "input_image"}
has_image if {
	some message in body.messages
	some part in message.content
	part.type in image_types
}
has_image if {
	some message in body.messages
	some part in message.content
	some nested in part.content
	nested.type in image_types
}

needs_vision if {
	has_image
	routed.pool == "private"
	routed.class in data.routing.classes_without_vision
}
needs_long_context if {
	body_readable
	not has_image
	routed.pool == "private"
	routed.class != data.routing.long_context_class
	count(http.body) / data.routing.bytes_per_token + object.get(body, "max_tokens", 0) > data.routing.small_window_tokens
}

# These adjustments stay inside the private pool.
decision := object.union(routed, {"class": data.routing.vision_fallback_class,
	"reason": sprintf("%s, image in prompt", [routed.reason])}) if needs_vision
else := object.union(routed, {"class": data.routing.long_context_class,
	"reason": sprintf("%s, too long for the smaller window", [routed.reason])}) if needs_long_context
else := routed

lane := data_class.class if data_class
else := "public" if { classifies_data; body_readable }
else := ""

# AGW consumes this object through extAuth dynamic metadata, not a client header.
base := {"user": subject, "task": task, "pool": "", "class": "", "lane": "",
	"status": 403, "reason": "", "error": "no suitable permitted backend for this task"}

outcome := object.union(base, {
	"status": 422, "reason": "blocked, credential in prompt",
	"error": "the prompt contains something that looks like a credential; remove it and try again",
}) if { known_caller; has_secret }
else := object.union(base, {
	"status": 422, "reason": "blocked, tries to override the model or carries a password",
	"error": "Stopped at the Kernwerk gateway. This request tries to override the model's rules or carries a password, so no model received it.",
}) if { known_caller; has_jailbreak }
else := object.union(object.union(base, decision), {"status": 200, "lane": lane}) if {
	known_caller
	decision
} else := base

# "allowed" lets AGW consume the metadata; it is not the access decision.
# AGW's PostRouting directResponse enforces outcome.status, including failures
# to receive a decision at all. This keeps the same errors for both client APIs.
result := {"allowed": true, "dynamic_metadata": {"routing": outcome}}
