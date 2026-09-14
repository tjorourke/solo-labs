# Which model a request goes to, decided by policy rather than by the gateway's own
# classifier or by the semantic router.
#
# Two inputs neither of those looks at: who is asking, and what they are entitled to.
# The team arrives in an x-team header so the rule is visible in curl. In production
# read it from a claim on a JWT the gateway has already verified: the JWT policy runs
# before extAuth, and the gateway forwards its claims to the authorizer as metadata.
package routing

# Who may use which model. Entitlements are the thing this option adds, and the thing
# a regex or a classifier cannot express.
entitlements := {
	"finance": {"mistral-small-3.2-24b"},
	"platform": {"mistral-small-3.2-24b", "qwen3-coder-30b"},
}

default_model := "mistral-small-3.2-24b"

team := input.attributes.request.http.headers["x-team"]

allowed_models := ms if {
	ms := entitlements[team]
} else := {default_model}

# forwardBody on the policy is what makes parsed_body exist. Without it OPA sees
# headers only and every request reads as "auto" with no prompt.
requested := object.get(input.parsed_body, "model", "auto")

# The last message, as text. Chat clients send content either as a string (curl, the
# OpenAI SDK) or as a list of typed parts (ADK, LiteLLM), and the rule reads both.
last_content := input.parsed_body.messages[count(input.parsed_body.messages) - 1].content

text := last_content if is_string(last_content)

text := last_content[0].text if is_array(last_content)

# The same pattern the keyword policy uses, so the two options differ only in what
# happens around the classification. OPA is not a better classifier than CEL.
looks_like_code if regex.match(`(?i)(code|function|python|javascript|refactor|debug|compile|regex|sql query|unit test)`, text)

# A named model is honoured when the team may use it.
chosen := requested if {
	requested != "auto"
	requested in allowed_models
}

# "auto" is classified, then held to what the team may use.
chosen := "qwen3-coder-30b" if {
	requested == "auto"
	looks_like_code
	"qwen3-coder-30b" in allowed_models
}

chosen := default_model if {
	requested == "auto"
	looks_like_code
	not "qwen3-coder-30b" in allowed_models
}

chosen := default_model if {
	requested == "auto"
	not looks_like_code
}

# When no rule chose a model the request is refused. A 403 with a reason is the
# answer the transformation cannot give: CEL can only write a header.
default result := {
	"allowed": false,
	"http_status": 403,
	"headers": {"content-type": "application/json"},
	"body": `{"error": {"type": "forbidden", "message": "no model this caller may use satisfies the request"}}`,
}

# Allow, and put the decision where the HTTPRoute can see it. `headers` lands on the
# request; `response_headers_to_add` goes back to the client, the way vSR's
# x-vsr-selected-model does, so the decision is visible in curl -i.
result := {
	"allowed": true,
	"headers": {"x-model": chosen},
	"response_headers_to_add": {"x-opa-decision": chosen},
} if {
	chosen
}
