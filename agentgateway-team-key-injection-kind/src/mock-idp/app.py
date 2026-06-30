"""
mock-idp — a tiny stand-in identity provider for the lab.

On startup it generates an RSA keypair and exposes:
  GET /jwks.json            the public key set agentgateway fetches to verify JWTs
  GET /token?team=&sub=     mints a fresh RS256 JWT with a `team` claim
  GET /healthz

The `team` claim is what agentgateway lifts into the x-team header and routes on,
so each team's request lands on its own backend (and therefore its own static
upstream key). Tokens are minted fresh per request so they never expire mid-demo.

Swap this for a real IdP (Entra, Keycloak, Auth0, Okta, Frontegg) by pointing the
EnterpriseAgentgatewayPolicy jwks.remote at the IdP's JWKS URL and matching the
issuer/audience — nothing else in the lab changes.
"""
from __future__ import annotations

import base64
import os
import time

import jwt  # PyJWT
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI

ISSUER = os.getenv("ISSUER", "https://mock-idp.teamkey.demo")
AUDIENCE = os.getenv("AUDIENCE", "agentgateway")
KID = os.getenv("KID", "teamkey-1")
TTL_SECONDS = int(os.getenv("TOKEN_TTL", "3600"))

# A FIXED signing key baked into the image, so the JWKS is stable and can be
# inlined into the EnterpriseAgentgatewayPolicy (jwks.inline). Falls back to a
# generated key if the PEM is absent (then use jwks.remote instead).
_KEY_PATH = os.getenv("SIGNING_KEY", "/app/signing-key.pem")
if os.path.exists(_KEY_PATH):
    with open(_KEY_PATH, "rb") as _f:
        _key = serialization.load_pem_private_key(_f.read(), password=None)
else:
    _key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_pub = _key.public_key().public_numbers()


def _b64u_uint(n: int) -> str:
    blen = (n.bit_length() + 7) // 8
    return base64.urlsafe_b64encode(n.to_bytes(blen, "big")).rstrip(b"=").decode()


_JWK = {
    "kty": "RSA",
    "use": "sig",
    "alg": "RS256",
    "kid": KID,
    "n": _b64u_uint(_pub.n),
    "e": _b64u_uint(_pub.e),
}

app = FastAPI(title="mock-idp", version="0.1.0")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "issuer": ISSUER}


@app.get("/jwks.json")
def jwks() -> dict[str, list[dict[str, str]]]:
    return {"keys": [_JWK]}


@app.get("/token")
def token(team: str = "sales", sub: str = "user") -> dict[str, str]:
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": sub,
        "team": team,
        "iat": now,
        "nbf": now,
        "exp": now + TTL_SECONDS,
    }
    tok = jwt.encode(claims, _key, algorithm="RS256", headers={"kid": KID})
    return {"team": team, "sub": sub, "token": tok}
