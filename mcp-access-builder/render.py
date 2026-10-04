#!/usr/bin/env python3
"""Render a reviewed MCP access catalogue into OSS AgentgatewayPolicy YAML.

Requires Python 3.10+ and PyYAML 6.0.3. Sources are files, stdin (-), or HTTPS URLs.
Nothing is applied to a cluster. See README.md for the catalogue contract.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

MAX_BYTES = 1024 * 1024
ID = re.compile(r"[a-z][a-z0-9-]{0,62}\Z")
DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")


class CatalogueError(ValueError):
    """Invalid source data. Do not publish any output."""


class CatalogueLoader(yaml.BaseLoader):
    """Strings, lists and mappings only, matching the browser FAILSAFE schema."""


def mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, str):
            raise CatalogueError("YAML mapping keys must be strings")
        if key in result:
            raise CatalogueError(f"Duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node)
    return result


CatalogueLoader.add_constructor("tag:yaml.org,2002:map", mapping)


def parse_yaml(text):
    if len(text.encode("utf-8")) > MAX_BYTES:
        raise CatalogueError("Each source must be at most 1 MiB")
    try:
        for token in yaml.scan(text):
            if isinstance(token, (yaml.tokens.AnchorToken, yaml.tokens.AliasToken, yaml.tokens.TagToken)):
                raise CatalogueError("YAML anchors, aliases and explicit tags are not supported")
        docs = list(yaml.load_all(text, Loader=CatalogueLoader))
    except yaml.YAMLError as error:
        raise CatalogueError(f"Invalid YAML: {error}") from error
    if not docs or any(doc is None or doc == "" for doc in docs):
        raise CatalogueError("Each YAML document must contain a catalogue")
    return docs


def obj(value, path, allowed, required=()):
    if not isinstance(value, dict):
        raise CatalogueError(f"{path}: expected a mapping")
    extra = sorted(set(value) - set(allowed))
    missing = sorted(set(required) - set(value))
    if extra:
        raise CatalogueError(f"{path}: unknown field {extra[0]}")
    if missing:
        raise CatalogueError(f"{path}: missing {missing[0]}")


def text(value, path):
    if not isinstance(value, str) or not value or len(value) > 256:
        raise CatalogueError(f"{path}: expected a non-empty string (maximum 256 characters)")
    if any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value):
        raise CatalogueError(f"{path}: control characters and invalid Unicode are not supported")
    return value


def identifier(value, path):
    text(value, path)
    if not ID.fullmatch(value):
        raise CatalogueError(f"{path}: use a lowercase ID beginning with a letter, maximum 63 characters")


def strings(value, path, empty=False):
    if not isinstance(value, list) or (not value and not empty):
        raise CatalogueError(f"{path}: expected {'a' if empty else 'a non-empty'} list")
    values = [text(v, f"{path}[{i}]") for i, v in enumerate(value)]
    if len(set(values)) != len(values):
        raise CatalogueError(f"{path}: duplicate entries")
    return sorted(values)


def compile_catalogue(documents):
    """Validate all documents, then expand grants to backend-local tool sets."""
    servers, grants = {}, {}
    for i, doc in enumerate(documents):
        path = f"document[{i}]"
        obj(doc, path, ("version", "servers", "grants"), ("version",))
        if doc["version"] != "1":
            raise CatalogueError(f"{path}.version: expected 1")
        incoming = doc.get("servers", {})
        if not isinstance(incoming, dict):
            raise CatalogueError(f"{path}.servers: expected a mapping")
        for name, server in incoming.items():
            identifier(name, "server ID")
            if name in servers:
                raise CatalogueError(f"Duplicate server ID: {name}")
            p = f"servers.{name}"
            obj(server, p, ("namespace", "backend", "toolSets"), ("namespace", "backend", "toolSets"))
            namespace = text(server["namespace"], p + ".namespace")
            backend = text(server["backend"], p + ".backend")
            if not DNS_LABEL.fullmatch(namespace):
                raise CatalogueError(f"{p}.namespace: expected a Kubernetes namespace (maximum 63 characters)")
            if len(backend) > 253 or not all(DNS_LABEL.fullmatch(part) for part in backend.split(".")):
                raise CatalogueError(f"{p}.backend: expected a Kubernetes DNS name")
            if not isinstance(server["toolSets"], dict):
                raise CatalogueError(f"{p}.toolSets: expected a mapping")
            sets = {}
            for key, tools in server["toolSets"].items():
                identifier(key, p + ".toolSets ID")
                sets[key] = strings(tools, p + ".toolSets." + key, empty=True)
                if any("*" in tool for tool in sets[key]):
                    raise CatalogueError(f"{p}.toolSets.{key}: list explicit tool names, not wildcards")
            servers[name] = {"namespace": namespace, "backend": backend, "toolSets": sets}
        incoming = doc.get("grants", [])
        if not isinstance(incoming, list):
            raise CatalogueError(f"{path}.grants: expected a list")
        for grant in incoming:
            obj(grant, "grant", ("name", "groups", "roles", "agentRoles", "access"), ("name", "access"))
            name = grant["name"]
            identifier(name, "grant.name")
            if name in grants:
                raise CatalogueError(f"Duplicate grant name: {name}")
            selectors = set(grant) & {"groups", "roles", "agentRoles"}
            if selectors not in ({"groups"}, {"roles"}, {"groups", "agentRoles"}):
                raise CatalogueError(f"grants.{name}: use groups, roles, or groups + agentRoles")
            normal = {"name": name, "access": strings(grant["access"], f"grants.{name}.access")}
            for key in sorted(selectors):
                normal[key] = strings(grant[key], f"grants.{name}.{key}")
            grants[name] = normal
    if not servers:
        raise CatalogueError("Define at least one server")
    if len(servers) > 500 or len(grants) > 2000:
        raise CatalogueError("Maximum 500 servers and 2000 grants per catalogue")
    targets = set()
    for name, server in servers.items():
        target = (server["namespace"], server["backend"])
        if target in targets:
            raise CatalogueError(f"servers.{name}: another server already targets this namespace/backend")
        targets.add(target)
    rows = {name: [] for name in servers}
    for name, grant in sorted(grants.items()):
        by_server = {}
        for reference in grant["access"]:
            parts = reference.split("/")
            if len(parts) != 2 or parts[0] not in servers or parts[1] not in servers[parts[0]]["toolSets"]:
                raise CatalogueError(f"grants.{name}.access: unknown tool set {reference}")
            server, tool_set = parts
            by_server.setdefault(server, set()).update(servers[server]["toolSets"][tool_set])
        for server, tools in sorted(by_server.items()):
            if tools:
                rows[server].append({"grant": grant, "tools": sorted(tools)})
    policies = []
    for name, server in sorted(servers.items()):
        expressions = [expression(row["grant"], row["tools"]) for row in rows[name]]
        policies.append({"server": name, "namespace": server["namespace"], "backend": server["backend"],
                         "name": "mcp-access-" + name, "expressions": expressions or ["false"], "rows": rows[name]})
    return {"policies": policies, "grantCount": len(grants)}


def quote(value):
    return json.dumps(value, ensure_ascii=True)


def cel_list(values):
    return "[" + ", ".join(quote(v) for v in values) + "]"


def claim_check(field, values):
    claim = "jwt." + field
    return f"has({claim}) && type({claim}) == list && {claim}.exists(v, v in {cel_list(values)})"


def expression(grant, tools):
    delegated = "agentRoles" in grant
    checks = ["has(jwt.act) && has(jwt.act.sub)" if delegated else "!has(jwt.act)"]
    for key, field in (("groups", "groups"), ("roles", "roles"), ("agentRoles", "agent_roles")):
        if key in grant:
            checks.append(claim_check(field, grant[key]))
    checks.append("mcp.tool.name in " + cel_list(tools))
    return "\n&& ".join(checks)


def render(compiled):
    docs = []
    for p in compiled["policies"]:
        lines = ["# Generated by MCP access builder. Edit the catalogue, not this file.",
                 "apiVersion: agentgateway.dev/v1alpha1", "kind: AgentgatewayPolicy", "metadata:",
                 "  name: " + quote(p["name"]), "  namespace: " + quote(p["namespace"]), "spec:",
                 "  targetRefs:", "    - group: agentgateway.dev", "      kind: AgentgatewayBackend",
                 "      name: " + quote(p["backend"]), "  backend:", "    mcp:", "      authorization:",
                 "        action: Allow", "        policy:", "          matchExpressions:"]
        for expr in p["expressions"]:
            lines.append("            - |-")
            lines.extend("              " + line for line in expr.splitlines())
        docs.append("\n".join(lines))
    return "\n---\n".join(docs) + "\n"


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_url(source):
    url = urllib.parse.urlsplit(source)
    if url.scheme != "https" or not url.hostname or url.username is not None or url.password is not None:
        raise CatalogueError("Remote sources must be HTTPS URLs without embedded credentials")


def read_source(source):
    if source == "-":
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    elif "://" in source:
        check_url(source)
        request = urllib.request.Request(source, headers={"User-Agent": "mcp-access-builder/1"})
        with urllib.request.build_opener(HTTPSRedirect).open(request, timeout=15) as response:
            raw = response.read(MAX_BYTES + 1)
    else:
        with open(source, "rb") as stream:
            raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise CatalogueError("Each source must be at most 1 MiB")
    return raw.decode("utf-8-sig")


def write_atomic(destination, content):
    path = Path(destination)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="+", help="YAML files, HTTPS URLs or - for stdin; multiple documents are merged")
    parser.add_argument("-o", "--output", help="Write atomically to this file (default: stdout)")
    parser.add_argument("--check", action="store_true", help="Validate without writing policy YAML")
    args = parser.parse_args(argv)
    try:
        if args.sources.count("-") > 1:
            raise CatalogueError("Read stdin only once")
        documents = []
        for source in args.sources:
            try:
                documents.extend(parse_yaml(read_source(source)))
            except (CatalogueError, OSError, UnicodeError, ValueError) as error:
                # Do not echo URL queries, which can contain signed download credentials.
                label = urllib.parse.urlsplit(source).hostname if "://" in source else source
                raise CatalogueError(f"Cannot load {label}: {type(error).__name__}" if "://" in source
                                     else f"{label}: {error}") from error
        compiled = compile_catalogue(documents)
        output = render(compiled)
        if len(output.encode("utf-8")) > 8 * MAX_BYTES:
            raise CatalogueError("Rendered output exceeds 8 MiB; split the catalogue")
        if args.check:
            print(f"Valid: {len(compiled['policies'])} backends, {compiled['grantCount']} grants", file=sys.stderr)
        elif args.output:
            write_atomic(args.output, output)
        else:
            sys.stdout.write(output)
        return 0
    except (CatalogueError, OSError, UnicodeError, RecursionError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
