FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
# kagent-core pulls in opentelemetry-instrumentation-* packages, all of which
# ship pre-release-only (e.g. 0.52b0). --pre lets pip accept those.
RUN pip install --no-cache-dir --pre -r requirements.txt

COPY agent.py cli.py agent-card.json ./

ENV PORT=8080
EXPOSE 8080

CMD ["python", "cli.py"]
