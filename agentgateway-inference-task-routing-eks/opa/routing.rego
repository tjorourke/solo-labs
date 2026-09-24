# Audit transport only. All decisions and enforcement are native AGW policies.
# The console needs an event before the model finishes, not only an access log
# at completion. Keep the existing ext_authz decision-log envelope for that event.
# Never interpret request headers here or add routing/response mutations.
package routing
import rego.v1
result := {"allowed": true}
