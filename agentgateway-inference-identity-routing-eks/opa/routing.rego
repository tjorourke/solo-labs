# Where an authenticated caller's inference may run.
#
# This is the whole of OPA's job in this lab. It does not read the prompt (the policy
# does not forward the body), it does not pick a model, and it holds no provider
# credential. It resolves the verified subject, looks the subject up in the entitlement
# data, and answers with a target the route can match, or a 403.
#
# The target is decided by one attribute first and one second. A user whose work is
# classified restricted never leaves the cluster: the target is self-hosted, whatever
# provider their contract names. Everyone else goes to the frontier provider their
# contract names. Which model answers on either side is not decided here; the semantic
# router picks the class and the backend picks the model.
package routing

# The subject the gateway verified. agentgateway validates the JWT before calling
# extAuth and, with no requestMetadata configured, forwards the claims under the
# envoy.filters.http.jwt_authn metadata key as {"jwt_payload": {...claims}}. The OPA
# plugin decodes the request with protojson, so the field names arrive camel-cased.
# This path is the one an OPA decision log showed for agentgateway v1.5.0, not a guess.
subject := input.attributes.metadataContext.filterMetadata["envoy.filters.http.jwt_authn"].jwt_payload.sub

# opa/entitlements.json is loaded as a data file, so its top-level keys sit directly
# under data: the lookup is data.users, with no file name in the path.
entitlement := data.users[subject]

# The only frontier providers the route knows. A typo in the data is refused here, with a
# reason, rather than becoming a request with no matching route.
known_providers := {"openai", "anthropic"}

# Restricted data stays on the GPUs in this cluster.
target := "self-hosted" if {
	entitlement.data == "restricted"
}

# Anything else may use the frontier provider the contract names.
target := entitlement.provider if {
	entitlement.data != "restricted"
	entitlement.provider in known_providers
}

default result := {
	"allowed": false,
	"http_status": 403,
	"headers": {"content-type": "application/json"},
	"body": `{"error": {"type": "forbidden", "message": "no inference entitlement for this identity"}}`,
}

# Allow, and write the attributes where the HTTPRoute can match them. The route reads
# x-routing-target only; the others are for logs and later policy.
#
# request_headers_to_remove runs before headers are added, so a client that sent its
# own x-routing-target loses it here. Where a request runs is decided server-side.
result := {
	"allowed": true,
	"request_headers_to_remove": ["x-routing-user", "x-routing-target", "x-routing-data", "x-routing-tier", "x-routing-region"],
	"headers": {
		"x-routing-user": subject,
		"x-routing-target": target,
		"x-routing-data": entitlement.data,
		"x-routing-tier": entitlement.tier,
		"x-routing-region": entitlement.region,
	},
	"response_headers_to_add": {"x-routing-target": target},
} if {
	target
}
