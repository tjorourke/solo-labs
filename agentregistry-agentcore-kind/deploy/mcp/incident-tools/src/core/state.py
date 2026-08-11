"""Shared in-memory demo state for the incident-tools server.

Static alert data plus the set of acknowledged ids. In-memory only: a pod
restart resets the demo, which is exactly what you want between runs.
"""

ALERTS = [
    {"id": "AL-1001", "service": "checkout", "severity": "critical",
     "summary": "p99 latency above 2s"},
    {"id": "AL-1002", "service": "checkout", "severity": "warning",
     "summary": "error rate climbing on POST /pay"},
    {"id": "AL-1003", "service": "payments", "severity": "critical",
     "summary": "connection pool exhausted"},
    {"id": "AL-1004", "service": "catalog", "severity": "info",
     "summary": "deployment rollout completed"},
    {"id": "AL-1005", "service": "payments", "severity": "warning",
     "summary": "retry storm from checkout callers"},
]

acked: set[str] = set()
