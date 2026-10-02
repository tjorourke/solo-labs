# One image, four MCP servers. The Deployment picks the domain with DOMAIN.
FROM python:3.12-alpine
COPY mcp_base.py bank_mcp.py /app/
WORKDIR /app
EXPOSE 3000
CMD ["python3", "/app/bank_mcp.py"]
