# record-tools

A one-tool MCP server. `record_diagnosis` carries the `Diagnosis` contract as its
input schema, so the declarative DBA agent has to answer in the shape and cannot
drift into free text. Served over streamable HTTP at `/mcp` on `:8080`.
