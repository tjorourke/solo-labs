"""Local health tool. ADK derives its schema from the signature and docstring."""

RESTART_LIMIT = 3
PENDING_LIMIT_MINUTES = 5


def unhealthy(phase: str, restarts: int, pending_minutes: int = 0) -> dict:
    """Decide whether one pod counts as unhealthy.

    A pod is unhealthy when it is not Running, or has restarted more than three times,
    or has been Pending for more than five minutes.

    Args:
        phase: the pod phase as reported by Kubernetes, for example Running or Pending.
        restarts: the container restart count.
        pending_minutes: how long the pod has been Pending, in minutes; 0 if it is not.

    Returns:
        unhealthy: true or false, and reason: which part of the rule decided it.
    """
    if phase != "Running":
        if phase == "Pending" and pending_minutes <= PENDING_LIMIT_MINUTES:
            return {"unhealthy": False, "reason": f"Pending for {pending_minutes} min, within the {PENDING_LIMIT_MINUTES} min allowance"}
        return {"unhealthy": True, "reason": f"phase is {phase}, not Running"}
    if restarts > RESTART_LIMIT:
        return {"unhealthy": True, "reason": f"{restarts} restarts, more than {RESTART_LIMIT}"}
    return {"unhealthy": False, "reason": "Running with an acceptable restart count"}
