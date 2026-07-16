# One image for the whole audit: the per-node collector (DaemonSet,
# default entrypoint) and the aggregator (CronJob overrides the command).
# Stdlib-only Python — the Kubernetes API is plain HTTPS + a ServiceAccount
# bearer token, so there is no pip layer to build or patch. Non-root.
FROM python:3.12-alpine
COPY collector.py aggregate.py /
USER 65532:65532
ENTRYPOINT ["python3", "-u", "/collector.py"]
