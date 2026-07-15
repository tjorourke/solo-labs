FROM python:3.12-slim

WORKDIR /app

# Deps first for layer caching.
RUN pip install --no-cache-dir "mcp>=1.12.0"

COPY record_tools/ record_tools/

ENV HOST=0.0.0.0 PORT=8080
EXPOSE 8080

CMD ["python", "-m", "record_tools.server"]
