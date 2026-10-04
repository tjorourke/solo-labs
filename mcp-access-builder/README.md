# MCP access policy builder

Store reviewed tool sets and access grants in YAML. Render one OSS
`AgentgatewayPolicy` per existing `AgentgatewayBackend`.

Browser: https://www.mastertheagent.com/solo/mcp-access-builder/

## Python

Requires Python 3.10+ and PyYAML. No cluster access is needed.

```sh
curl -fLO https://www.mastertheagent.com/solo/mcp-access-builder/render.py
curl -fLO https://www.mastertheagent.com/solo/mcp-access-builder/example.yaml
curl -fLO https://www.mastertheagent.com/solo/mcp-access-builder/requirements.txt
python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements.txt
python3 render.py example.yaml --check
python3 render.py example.yaml --output policies.yaml
```

The script accepts one or more YAML files, HTTPS URLs, or `-` for stdin:

```sh
python3 render.py servers/*.yaml grants.yaml --output policies.yaml
python3 render.py https://raw.githubusercontent.com/ORG/REPO/COMMIT/access.yaml \
  --output policies.yaml
```

Use raw file URLs, preferably pinned to a commit. Remote reads have a 15-second
socket timeout and a 1 MiB size limit per source. Redirects must remain HTTPS.
For private repositories, use your CI's authenticated checkout or fetch step and
pass local files. The renderer does not accept credentials embedded in URLs.

Without `--output`, policy YAML goes to stdout. `--check` validates without
writing output. Invalid input exits with code 2; an existing output file is left
untouched. Nothing is applied to Kubernetes.

## Catalogue format

This is this tool's input format, not an agentgateway CRD.

```yaml
version: 1
servers:
  github:
    namespace: ops-tools
    backend: github-mcp
    toolSets:
      reader: [search_repositories, get_pull_request]
      writer: [create_pull_request]
grants:
  - name: developers
    groups: [development]
    access: [github/reader]
```

- Each document requires `version: 1`. `servers` and `grants` are optional in an
  individual document, allowing server definitions and grants in separate files.
  The combined input must contain at least one server.
- Multiple files and `---`-separated documents are merged before validation.
  Duplicate server IDs or grant names are errors, not overrides.
- Server, tool-set and grant IDs use lowercase letters, digits and hyphens,
  start with a letter and are at most 63 characters. Namespace and backend names
  must be valid Kubernetes DNS names. Only one server may target a given
  namespace/backend pair.
- `toolSets` maps names to explicit tool-name lists. Empty sets are allowed.
  Wildcards are rejected. A tool may belong to several sets.
- `access` is a non-empty list of `server/tool-set` references. Sets are expanded,
  unioned and deduplicated for each grant/backend. Unknown references fail the
  whole render.
- Unknown fields, duplicate mapping keys or duplicate list entries fail validation.
  YAML scalars are strings, including IDs such as `on` or `2026-10-04`.
  Anchors, aliases and explicit YAML tags are not supported.
- Limits: 1 MiB per input source (1 MiB combined in the browser), 500 servers,
  2,000 grants and 8 MiB total rendered output. Split larger catalogues.

### Grant types

| Input selectors | Verified JWT claims | Behaviour |
| --- | --- | --- |
| `groups: [development]` | `jwt.groups` | Direct users; excludes tokens with `act` |
| `roles: [finance-reader]` | `jwt.roles` | Autonomous agents; excludes tokens with `act` |
| `groups: [finance]` and `agentRoles: [finance-reader]` | `jwt.groups`, `jwt.agent_roles`, `jwt.act.sub` | Delegated calls; both user group and current agent role must match |

Values within each selector list are alternatives. Different grants are
alternatives too. In a delegated grant, group and agent-role conditions are
joined with AND. Combining `groups` and `roles`, or specifying `agentRoles`
alone, is rejected rather than guessing at the intended semantics.

Missing or non-list group/role claims do not match. JWT issuer, audience and
signature checks belong in route authentication and are not emitted here.
The trusted issuers must control the claims and distinguish user, autonomous
and delegated tokens consistently. `roles` and `agent_roles` are custom claims,
not fields Kubernetes adds to ServiceAccount tokens.

## Output and deployment

Output is deterministic: servers, grants, selectors and tool names are sorted.
Policy names are `mcp-access-<server-id>` and policies live in the target backend's
namespace. A backend without an effective grant receives an Allow expression
of `false`. Tool names are JSON-escaped before embedding in CEL.

Use one backend per server. This version does not distinguish multiple upstream
MCP targets within one aggregated backend, issue tokens, discover live tools,
configure JWT authentication, generate Enterprise API resources or deploy OPA.

A suggested CI flow:

1. Validate source YAML with `--check`.
2. Render and review the policy diff. Review newly added tools before granting them.
3. Test discovery and direct calls with allowed and denied identities.
4. Deploy the generated resources through your existing GitOps process.

Replace any previous allow policies for the same backends. Other matching allow
rules can broaden access; adding a `false` alternative does not override them.
**Removing a server from the catalogue is not a revocation operation.** Keep it
in the catalogue without grants to generate a deny policy while you retire its
route. Do not prune the last authorisation policy from a still-accessible backend.
Renaming a server ID changes its policy name and needs an explicit migration.

## Browser

Paste YAML, open one or more files, or load a public HTTPS YAML URL. Remote URLs
must allow browser cross-origin requests. Catalogue content stays in the browser;
the site has no rendering API. The YAML parser is js-yaml 4.1.1, loaded from a
pinned CDN URL with an integrity hash. The Python renderer works offline once
PyYAML is installed.

Changing the source clears the generated output and disables export until a
successful render. The access summary shows each expanded grant and the backends
that deny all tools. Downloads include the catalogue, complete policy YAML and
the Python script. CEL-only view is useful for inspection; deploy policy YAML.

## Tests

```sh
python3 test_render.py
```

Requires Node.js as well as the Python dependencies. Tests cover validation,
escaping, deterministic multi-file merging, empty-grant denial, a 50-server /
2,500-tool catalogue, CLI failure behaviour and byte-for-byte parity between
Python and the browser core. Browser interaction and live gateway checks are
separate from these unit tests.

Live validation on 4 October 2026 used OSS agentgateway v1.5.0. The generated
example policies passed 48 caller/backend combinations across four MCP backends,
including tool discovery and 480 direct tool calls. The cases covered direct
users, autonomous agents, delegated calls, malformed claims and backend isolation.

For tests, fetch the complete `mcp-access-builder` directory from
https://github.com/tjorourke/solo-labs/tree/main/mcp-access-builder so that
`render.py`, `core.js`, `example.yaml` and `test_render.py` are alongside each other.
