FROM python:3.12-slim
# Pin below 2: mcp 2.x renamed FastMCP to MCPServer, so an unpinned build resolves to a
# release this server cannot import and the pod crash-loops with the image built fine.
RUN pip install --no-cache-dir "mcp>=1.2,<2"
WORKDIR /app
COPY server.py .
EXPOSE 3000
CMD ["python", "server.py"]
