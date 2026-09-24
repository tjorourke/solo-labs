#!/usr/bin/env python3
"""Create the sandbox Secret without placing the provider key in command arguments."""
import os
import subprocess

context = os.environ.get("KUBE_CONTEXT")
key = os.environ.get("TYPESAFE_API_KEY")
if not context or not key:
    raise SystemExit("Set KUBE_CONTEXT and TYPESAFE_API_KEY first")
command = ["kubectl", "--context", context, "-n", "jev-routing-kb"]
result = subprocess.run(command + ["create", "secret", "generic", "typesafe",
    "--from-file=TYPESAFE_API_KEY=/dev/stdin", "--dry-run=client", "-o", "json"],
    input=key.encode(), stdout=subprocess.PIPE, check=True)
subprocess.run(command + ["apply", "-f", "-"], input=result.stdout, check=True)
