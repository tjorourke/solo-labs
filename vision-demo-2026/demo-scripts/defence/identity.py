"""Lab-local RS256 keys and short-lived test users. Never prints the private key.

setup creates a public JWT policy file; token signs an ordinary user claim.
Requires the same cryptography package used by the Model access lab.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import tempfile
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

STATE = Path(os.environ.get("DD_STATE", str(Path(tempfile.gettempdir()) / "defence-lab")))


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=["setup", "token"])
    ap.add_argument("--user", default="alice")
    ap.add_argument("--group", default="reader")
    args = ap.parse_args()
    if args.action == "setup":
        STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
        keyfile = STATE / "private.pem"
        if not keyfile.exists():
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            with keyfile.open("xb") as f:
                os.chmod(keyfile, 0o600)
                f.write(key.private_bytes(serialization.Encoding.PEM,
                                         serialization.PrivateFormat.PKCS8,
                                         serialization.NoEncryption()))
        key = serialization.load_pem_private_key(keyfile.read_bytes(), password=None)
        numbers = key.public_key().public_numbers()
        jwks = {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": "dd-idp",
                         "n": b64(numbers.n.to_bytes(256, "big")),
                         "e": b64(numbers.e.to_bytes(3, "big"))}]}
        policy = {"apiVersion": "enterpriseagentgateway.solo.io/v1alpha1",
                  "kind": "EnterpriseAgentgatewayPolicy",
                  "metadata": {"name": "caller-identity", "namespace": "dd-gateway"},
                  "spec": {"targetRefs": [{"group": "gateway.networking.k8s.io",
                                           "kind": "Gateway", "name": "dd-gateway"}],
                           "traffic": {"jwtAuthentication": {"mode": "Strict", "providers": [
                               {"issuer": "https://defence.demo.example/",
                                "audiences": ["defence-lab"],
                                "jwks": {"inline": json.dumps(jwks)}}]}}}}
        (STATE / "07-caller-identity.json").write_text(json.dumps(policy, indent=2) + "\n")
        print("Lab signing key ready; public JWT policy rendered")
        return
    key = serialization.load_pem_private_key((STATE / "private.pem").read_bytes(), password=None)
    header = b64(json.dumps({"alg": "RS256", "typ": "JWT", "kid": "dd-idp"}).encode())
    claims = b64(json.dumps({"iss": "https://defence.demo.example/", "aud": "defence-lab",
                            "sub": args.user, "group": args.group,
                            "iat": int(time.time()), "exp": int(time.time()) + 3600}).encode())
    signing = f"{header}.{claims}".encode()
    print(signing.decode() + "." + b64(key.sign(signing, padding.PKCS1v15(), hashes.SHA256())))


if __name__ == "__main__":
    main()
