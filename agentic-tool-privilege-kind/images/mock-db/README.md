# mock-db

A simulated Postgres exposed as an MCP server — no real database is deployed. It
pretends to be the locked-out `orders` database and exposes read tools
(`db_status`, `list_tables`, `db_query`) plus one privileged write tool
(`db_reset_credentials`) that unlocks it. The server never checks identity;
agentgateway decides which caller may reach which tool.
