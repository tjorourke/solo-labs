FROM python:3.12-slim
RUN pip install --no-cache-dir "mcp>=1.2"
WORKDIR /app
COPY server.py .
EXPOSE 3000
CMD ["python", "server.py"]
