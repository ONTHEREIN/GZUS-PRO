"""Direct API test with verbose output."""
from __future__ import annotations

import httpx

account = "2540232101"
password = "Limuliseig423."

r = httpx.post(
    "http://localhost:8000/auth/auto-login",
    json={"account": account, "password": password},
    timeout=120,
)
print(f"Status: {r.status_code}")
print(f"Body: {r.text}")
