package routing_test

import rego.v1

request(claims) := {"attributes": {
	"metadataContext": {"filterMetadata": {"envoy.filters.http.jwt_authn": {"jwt_payload": claims}}},
	"request": {"http": {
		"headers": {"x-selected-model": "generic_coding", "x-model-pool": "approved-frontier"},
		"body": `{"messages":[{"role":"user","content":"Explain lists."}]}`,
	}},
}}

test_ten_thousand_new_identities_need_no_policy_registration if {
	every n in numbers.range(1, 10000) {
		claims := {"iss": "https://identity.lab", "sub": sprintf("employee-%d", [n]), "groups": ["model-private"]}
		out := data.routing.outcome with input as request(claims)
		out.status == 200
		out.pool == "private"
		out.user == claims.sub
	}
}

test_missing_malformed_unknown_groups_fail_closed if {
	every groups in [[], ["unknown"], "model-frontier", null, 42, {"model-frontier": true}] {
		out := data.routing.outcome with input as request({"iss": "https://identity.lab", "sub": "bob", "groups": groups})
		out.status == 403
	}
}

test_names_and_email_do_not_grant_permission if {
	out := data.routing.outcome with input as request({"iss": "https://identity.lab", "sub": "bob", "email": "martink@corp.example"})
	out.status == 403
}

test_controller_groups_must_come_from_idp if {
	out := data.routing.outcome with input as request({"iss": "agentdesktop-controller", "sub": "uuid", "groups": ["model-frontier"]})
	out.status == 403
}

test_controller_idp_groups_work_for_unknown_person if {
	out := data.routing.outcome with input as request({"iss": "agentdesktop-controller", "sub": "uuid", "idp": {"email": "new.person@corp.example", "groups": ["model-private"]}})
	out.status == 200
	out.pool == "private"
	out.user == "new.person"
}

test_lab_issuer_cannot_use_nested_controller_claims if {
	out := data.routing.outcome with input as request({"iss": "https://identity.lab", "sub": "uuid", "idp": {"groups": ["model-frontier"]}})
	out.status == 403
}

test_groups_cannot_grant_a_pool_without_matching_role if {
	out := data.routing.outcome with input as request({"iss": "https://identity.lab", "sub": "uuid", "groups": ["approved-frontier", "admin"]})
	out.status == 403
}
