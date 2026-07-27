FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
# --pre for kagent-core's pre-release otel deps (mcp pinned <2 in requirements).
RUN pip install --no-cache-dir --pre -r requirements.txt

COPY agent.py main.py agent-card.json ./

ENV PORT=8080
EXPOSE 8080

CMD ["python", "main.py"]
