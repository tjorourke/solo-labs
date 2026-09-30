# One image, two MCP servers. The Deployment picks which with the command.
FROM python:3.12-alpine
COPY mcp_base.py quiz_mcp.py excuses_mcp.py /app/
WORKDIR /app
EXPOSE 3000
CMD ["python3", "/app/quiz_mcp.py"]
