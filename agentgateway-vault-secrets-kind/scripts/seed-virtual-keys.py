#!/usr/bin/env python3
"""Prints one `vault kv put ...` command per demo user, consumed by
scripts/quick.sh's `up` case (piped through `eval "vault_exec $line"`).

Each user's JSON blob (keyHash + metadata) is identical to the plaintext
ConfigMap shape in agentgateway-virtual-keys/yaml/virtual-keys.yaml, just
written into Vault KV v2 instead of a Kubernetes ConfigMap. Clients still
send the same demo bearer credential, vk-demo-<user>-not-for-production;
only where the hash is stored has moved. The blob sits under a single field
called "value", and eso-external-secret.yaml sets remoteRef.property: value to
unwrap it. Without property, ESO writes the whole KV object ({"value": ...})
into the Secret and agentgateway rejects every entry with "exactly one of key
or keyHash must be set".
"""
import json

USERS = {
    "alice": {
        "keyHash": "sha256:31d8c74a1afe597cdd957ed2905edef0a011cb2962922de2cd4c610922fab3d6",
        "metadata": {
            "id": "alice", "user": "alice", "group": "engineering",
            "costCenter": "cc-product", "environment": "dev",
            "allowedModels": ["virtual-key-demo", "silver"],
        },
    },
    "bob": {
        "keyHash": "sha256:dffefed88cd2a65d68488f4b55941e8a3e66e8cef88a3bda867aec77eea5cfce",
        "metadata": {
            "id": "bob", "user": "bob", "group": "engineering",
            "costCenter": "cc-product", "environment": "dev",
            "allowedModels": ["virtual-key-demo", "silver", "gold"],
        },
    },
    "carol": {
        "keyHash": "sha256:b58cb1765574b56834aa725823267857b945109b1d425ec23cf98f5bcb882edf",
        "metadata": {
            "id": "carol", "user": "carol", "group": "engineering",
            "costCenter": "cc-product", "environment": "dev",
            "allowedModels": ["virtual-key-demo", "silver"],
        },
    },
    "dave": {
        "keyHash": "sha256:83de07a9c838d6352feba319d00078da7731fa183b95fd2286106fda1c4d17c2",
        "metadata": {
            "id": "dave", "user": "dave", "group": "research",
            "costCenter": "cc-research", "environment": "dev",
            "allowedModels": ["virtual-key-demo", "silver", "gold"],
        },
    },
}

for user, blob in USERS.items():
    value = json.dumps(blob)
    print(f"vault kv put secret/virtual-keys/{user} value='{value}'")
