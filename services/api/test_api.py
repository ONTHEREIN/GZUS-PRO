"""Direct API test with verbose output."""
from __future__ import annotations

import os

import httpx

account = os.environ.get("GZUS_TEST_ACCOUNT")
password = os.environ.get("GZUS_TEST_PASSWORD")

if not account or not password:
    raise SystemExit("Set GZUS_TEST_ACCOUNT and GZUS_TEST_PASSWORD to run this manual test.")

r = httpx.post(
    "http://localhost:8000/auth/auto-login",
    json={"account": account, "password": password},
    timeout=120,
)
print(f"Status: {r.status_code}")
try:
    data = r.json()
except ValueError:
    print("Body: <non-json response>")
else:
    print(
        {
            "status": data.get("status"),
            "hasSession": bool(data.get("sessionId")),
            "hasCredentialToken": bool(data.get("credentialToken")),
        }
    )
