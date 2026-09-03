# Agentdesktop: governing the AI tools on developer laptops

An introduction to [Agentdesktop](https://github.com/agentdesktop-dev/agentdesktop),
the Apache 2.0 project from Solo.io that gives a platform team visibility and control
over the AI developer tools running across its fleet.

Read the lab: <https://www.masterthemesh.com/solo/agentdesktop-standalone/>

## What the lab covers

- What Agentdesktop is and where it sits relative to MDM.
- Running the standalone example: Dex plus agentgateway in Docker, one YAML file,
  no Kubernetes and no controller.
- Tool discovery, and the MCP and skill inventory that deliberately collects no
  command arguments, environment variables, headers or skill bodies.
- One `sandbox:` block translated into both Claude Code's JSON and Codex's TOML.
- A short-lived OIDC credential replacing the provider key on the workstation, and
  the gateway log line that carries a named user on every model request.
- What a business gets, and what changes when you move from standalone to a
  controller-managed fleet.

## Files

| Path | What it is |
| --- | --- |
| `index.html` | The lab. |
| `yaml/config.yaml` | A daemon config with `sandbox` and `telemetry` set, beyond what the upstream standalone example ships. |

The Dex, compose and agentgateway files come from the upstream repository under
`examples/standalone/`, so clone that and use `yaml/config.yaml` here in place of
`examples/standalone/config.yaml`.

## Quick start

```sh
git clone https://github.com/agentdesktop-dev/agentdesktop.git
cd agentdesktop

# Device binary from the release, or `corepack enable && make install` to build.
gh release download v0.1.0 --repo agentdesktop-dev/agentdesktop \
  --pattern 'agentdesktop-darwin-arm64*' --dir bin
cd bin && shasum -a 256 -c agentdesktop-darwin-arm64.sha256
mv agentdesktop-darwin-arm64 agentdesktop && chmod +x agentdesktop
cd .. && export PATH="$PWD/bin:$PATH"

export ANTHROPIC_API_KEY=sk-ant-...
docker compose -f examples/standalone/compose.yaml up -d

# Preview every file the daemon would change, without changing any of them.
agentdesktop daemon --config examples/standalone/config.yaml --user --dry-run

# Apply, then sign in as admin@example.com / password.
agentdesktop daemon --config examples/standalone/config.yaml --user
```

Then, in another terminal:

```sh
agentdesktop status
agentdesktop discover
agentdesktop            # no subcommand: the desktop interface
```

Start the daemon before the interface. If no daemon is running, the interface
installs a per-user LaunchAgent and starts its own against an empty config.

Teardown:

```sh
docker compose -f examples/standalone/compose.yaml down
```

## Tested

OSS only; there is no Enterprise edition of Agentdesktop. Validated 2026-09-03 on
Agentdesktop v0.1.0 with agentgateway v1.4.1 (Apache 2.0, file-configured standalone
mode) and Dex v2.45.1, on macOS arm64.
