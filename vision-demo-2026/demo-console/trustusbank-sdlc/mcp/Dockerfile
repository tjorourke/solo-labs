# One image, two MCP servers. The Deployment picks pm or dev tools with ROLE.
FROM python:3.12-alpine
COPY mcp_base.py github_mcp.py /app/
WORKDIR /app
EXPOSE 3000
USER 65534
CMD ["python3", "/app/github_mcp.py"]
