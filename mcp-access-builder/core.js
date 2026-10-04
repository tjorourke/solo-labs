/* Browser counterpart to render.py. Byte-for-byte parity is checked in tests. */
(function (root) {
  'use strict';
  const MAX_BYTES = 1024 * 1024;
  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const mapping = v => v !== null && typeof v === 'object' && !Array.isArray(v);
  const fail = message => { throw new Error(message); };
  const compare = (a, b) => {
    const x = Array.from(a, c => c.codePointAt(0)), y = Array.from(b, c => c.codePointAt(0));
    for (let i = 0; i < Math.min(x.length, y.length); i++) if (x[i] !== y[i]) return x[i] - y[i];
    return x.length - y.length;
  };
  const sorted = a => [...a].sort(compare);
  function obj(v, path, allowed, required = []) {
    if (!mapping(v)) fail(`${path}: expected a mapping`);
    const extra = sorted(Object.keys(v).filter(k => !allowed.includes(k)));
    const missing = sorted(required.filter(k => !own(v, k)));
    if (extra.length) fail(`${path}: unknown field ${extra[0]}`);
    if (missing.length) fail(`${path}: missing ${missing[0]}`);
  }
  function text(v, path) {
    if (typeof v !== 'string' || !v || Array.from(v).length > 256)
      fail(`${path}: expected a non-empty string (maximum 256 characters)`);
    for (const c of v) {
      const n = c.codePointAt(0);
      if (n < 32 || n === 127 || (n >= 0xd800 && n <= 0xdfff))
        fail(`${path}: control characters and invalid Unicode are not supported`);
    }
    return v;
  }
  function identifier(v, path) {
    text(v, path);
    if (!/^[a-z][a-z0-9-]{0,62}$/.test(v)) fail(`${path}: use a lowercase ID beginning with a letter, maximum 63 characters`);
  }
  function strings(v, path, empty = false) {
    if (!Array.isArray(v) || (!empty && !v.length)) fail(`${path}: expected ${empty ? 'a' : 'a non-empty'} list`);
    const values = v.map((x, i) => text(x, `${path}[${i}]`));
    if (new Set(values).size !== values.length) fail(`${path}: duplicate entries`);
    return sorted(values);
  }
  const quote = v => JSON.stringify(v).replace(/[\u0080-\uffff]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
  const celList = values => '[' + values.map(quote).join(', ') + ']';
  const claimCheck = (field, values) => `has(jwt.${field}) && type(jwt.${field}) == list && jwt.${field}.exists(v, v in ${celList(values)})`;
  function expression(grant, tools) {
    const checks = [own(grant, 'agentRoles') ? 'has(jwt.act) && has(jwt.act.sub)' : '!has(jwt.act)'];
    for (const [key, field] of [['groups', 'groups'], ['roles', 'roles'], ['agentRoles', 'agent_roles']])
      if (own(grant, key)) checks.push(claimCheck(field, grant[key]));
    checks.push('mcp.tool.name in ' + celList(tools));
    return checks.join('\n&& ');
  }
  function compile(documents) {
    const servers = new Map(), grants = new Map();
    documents.forEach((doc, i) => {
      const path = `document[${i}]`;
      obj(doc, path, ['version', 'servers', 'grants'], ['version']);
      if (doc.version !== '1') fail(`${path}.version: expected 1`);
      let incoming = own(doc, 'servers') ? doc.servers : {};
      if (!mapping(incoming)) fail(`${path}.servers: expected a mapping`);
      for (const [name, server] of Object.entries(incoming)) {
        identifier(name, 'server ID');
        if (servers.has(name)) fail(`Duplicate server ID: ${name}`);
        const p = `servers.${name}`;
        obj(server, p, ['namespace', 'backend', 'toolSets'], ['namespace', 'backend', 'toolSets']);
        const namespace = text(server.namespace, p + '.namespace'), backend = text(server.backend, p + '.backend');
        const dns = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
        if (!dns.test(namespace)) fail(`${p}.namespace: expected a Kubernetes namespace (maximum 63 characters)`);
        if (backend.length > 253 || !backend.split('.').every(x => dns.test(x))) fail(`${p}.backend: expected a Kubernetes DNS name`);
        if (!mapping(server.toolSets)) fail(`${p}.toolSets: expected a mapping`);
        const sets = new Map();
        for (const [key, tools] of Object.entries(server.toolSets)) {
          identifier(key, p + '.toolSets ID');
          const values = strings(tools, p + '.toolSets.' + key, true);
          if (values.some(t => t.includes('*'))) fail(`${p}.toolSets.${key}: list explicit tool names, not wildcards`);
          sets.set(key, values);
        }
        servers.set(name, {namespace, backend, toolSets: sets});
      }
      incoming = own(doc, 'grants') ? doc.grants : [];
      if (!Array.isArray(incoming)) fail(`${path}.grants: expected a list`);
      for (const grant of incoming) {
        obj(grant, 'grant', ['name', 'groups', 'roles', 'agentRoles', 'access'], ['name', 'access']);
        const name = grant.name;
        identifier(name, 'grant.name');
        if (grants.has(name)) fail(`Duplicate grant name: ${name}`);
        const selectors = sorted(Object.keys(grant).filter(k => ['groups', 'roles', 'agentRoles'].includes(k)));
        if (!['groups', 'roles', 'agentRoles,groups'].includes(selectors.join(','))) fail(`grants.${name}: use groups, roles, or groups + agentRoles`);
        const normal = {name, access: strings(grant.access, `grants.${name}.access`)};
        for (const key of selectors) normal[key] = strings(grant[key], `grants.${name}.${key}`);
        grants.set(name, normal);
      }
    });
    if (!servers.size) fail('Define at least one server');
    if (servers.size > 500 || grants.size > 2000) fail('Maximum 500 servers and 2000 grants per catalogue');
    const targets = new Set(), rows = new Map();
    for (const [name, s] of servers) {
      const target = s.namespace + '/' + s.backend;
      if (targets.has(target)) fail(`servers.${name}: another server already targets this namespace/backend`);
      targets.add(target); rows.set(name, []);
    }
    for (const name of sorted(grants.keys())) {
      const grant = grants.get(name), byServer = new Map();
      for (const reference of grant.access) {
        const parts = reference.split('/');
        if (parts.length !== 2 || !servers.has(parts[0]) || !servers.get(parts[0]).toolSets.has(parts[1]))
          fail(`grants.${name}.access: unknown tool set ${reference}`);
        const [server, toolSet] = parts;
        if (!byServer.has(server)) byServer.set(server, new Set());
        for (const tool of servers.get(server).toolSets.get(toolSet)) byServer.get(server).add(tool);
      }
      for (const server of sorted(byServer.keys())) {
        const tools = sorted(byServer.get(server));
        if (tools.length) rows.get(server).push({grant, tools});
      }
    }
    const policies = sorted(servers.keys()).map(name => {
      const server = servers.get(name), expressions = rows.get(name).map(r => expression(r.grant, r.tools));
      return {server: name, namespace: server.namespace, backend: server.backend, name: 'mcp-access-' + name,
        expressions: expressions.length ? expressions : ['false'], rows: rows.get(name)};
    });
    return {policies, grantCount: grants.size};
  }
  function render(compiled) {
    const output = compiled.policies.map(p => {
      const lines = ['# Generated by MCP access builder. Edit the catalogue, not this file.',
        'apiVersion: agentgateway.dev/v1alpha1', 'kind: AgentgatewayPolicy', 'metadata:',
        '  name: ' + quote(p.name), '  namespace: ' + quote(p.namespace), 'spec:',
        '  targetRefs:', '    - group: agentgateway.dev', '      kind: AgentgatewayBackend',
        '      name: ' + quote(p.backend), '  backend:', '    mcp:', '      authorization:',
        '        action: Allow', '        policy:', '          matchExpressions:'];
      for (const expr of p.expressions) {
        lines.push('            - |-');
        lines.push(...expr.split('\n').map(line => '              ' + line));
      }
      return lines.join('\n');
    }).join('\n---\n') + '\n';
    if (new TextEncoder().encode(output).length > 8 * MAX_BYTES) fail('Rendered output exceeds 8 MiB; split the catalogue');
    return output;
  }
  function parse(source, yaml) {
    if (new TextEncoder().encode(source).length > MAX_BYTES) fail('Each source must be at most 1 MiB');
    const documents = yaml.loadAll(source, null, {schema: yaml.FAILSAFE_SCHEMA, listener(event, state) {
      if (event === 'close' && (state.anchor !== null || (state.tag !== null && state.tag !== '?')))
        fail('YAML anchors, aliases and explicit tags are not supported');
    }});
    if (!documents.length || documents.some(d => d === null || d === '')) fail('Each YAML document must contain a catalogue');
    return documents;
  }
  const api = {compile, render, parse, MAX_BYTES};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.MCPAccess = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
