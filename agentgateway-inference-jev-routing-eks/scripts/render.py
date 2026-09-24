#!/usr/bin/env python3
"""Render the KB experiment to stdout. No Kubernetes or cloud calls."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def render(edition, image, profile_path, profile_name, routes=None):
    # Prevent YAML injection. Require a registry path and a tag or digest.
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._:/@-]+", image) or "/" not in image or ":" not in image.rsplit("/", 1)[-1]:
        raise ValueError("image must be a registry/repository:tag or registry/repository@sha256:digest")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", profile_name):
        raise ValueError("profile name must be a DNS label of at most 40 characters")
    raw = Path(profile_path).read_text()
    json.loads(raw)  # Detailed semantic validation happens in the adapter at startup.
    digest = hashlib.sha256(raw.encode()).hexdigest()[:12]
    configmap_name = f"{profile_name}-{digest}"
    configmap = {"apiVersion": "v1", "kind": "ConfigMap", "immutable": True,
        "metadata": {"name": configmap_name, "namespace": "jev-routing-kb",
                     "labels": {"app.kubernetes.io/part-of": "jev-routing-kb"}},
        "data": {"profile.json": raw}}
    folder = ROOT / ("yaml-oss" if edition == "oss" else "yaml")
    paths = [ROOT / "yaml/10-services.yaml", folder / "20-gateway.yaml", Path(routes) if routes else folder / "30-routes.yaml"]
    return "\n---\n".join([json.dumps(configmap, indent=2)] +
        [p.read_text().replace("__IMAGE__", image).replace("__PROFILE_CONFIGMAP__", configmap_name) for p in paths])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--edition", choices=["oss", "enterprise"], required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--profile", type=Path, default=ROOT / "config/task-routing.json")
    parser.add_argument("--profile-name", default="jev-task-profile")
    parser.add_argument("--routes", type=Path, help="Override the selected edition's route manifest")
    args = parser.parse_args()
    try:
        print(render(args.edition, args.image, args.profile, args.profile_name, args.routes))
    except (ValueError, OSError) as error:
        parser.error(str(error))
