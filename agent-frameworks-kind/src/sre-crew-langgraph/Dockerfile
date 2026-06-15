FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
# kagent-core pulls pre-release opentelemetry-instrumentation packages; --pre
# lets pip accept them.
RUN pip install --no-cache-dir --pre -r requirements.txt

COPY agent.py cli.py agent-card.json ./

ENV PORT=8080
EXPOSE 8080

CMD ["python", "cli.py"]
