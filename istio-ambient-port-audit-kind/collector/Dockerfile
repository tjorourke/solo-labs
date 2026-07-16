# The per-node collector. Stdlib-only Python (the Kubernetes API is plain
# HTTPS + a ServiceAccount bearer token), so there is no pip layer to build
# or patch. Runs as a non-root user.
FROM python:3.12-alpine
COPY collector.py /collector.py
USER 65532:65532
ENTRYPOINT ["python3", "-u", "/collector.py"]
