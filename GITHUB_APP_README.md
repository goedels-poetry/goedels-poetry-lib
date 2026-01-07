# GITHUB_APP_README — GitHub App for Automated Theorem PRs

This document describes what the GitHub App must do and how to build it so a Python proof-generation client can use it to author PRs that add new theorems to this repository.

## Purpose
- Provide scoped, non-human credentials to the repo.
- Issue short-lived installation access tokens (IAT) to the Python client.
- Optionally expose a small service endpoint for the client to request an IAT.
- Receive webhooks to observe PR lifecycle and CI outcomes (optional but recommended for observability/retries).

## Required GitHub App configuration
- **Permissions**
  - Repository: `contents:write`, `pull_requests:write`, `metadata:read`, `statuses:read` (or `checks:read`).
  - Webhooks: read-only; no admin permissions needed.
- **Events to subscribe (recommended)**
  - `pull_request`
  - `check_suite` and `check_run` (or `status`)
  - `push` (optional; useful for branch-state tracking)
- **Installation**
  - Install the App on the target repository (or org) and note the installation ID.
  - Store App ID and private key (PEM).
- **Callback URLs**
  - Webhook endpoint (e.g., `/webhook`).
  - Optional token-issuance endpoint (e.g., `/token`) if you want the App to mint IATs on behalf of the client rather than the client holding the private key.

## Authentication flows
Two patterns work; choose one:
1) **Client holds private key** (simpler; no token service): the Python client signs a JWT and calls `POST /app/installations/{installation_id}/access_tokens` directly.
2) **App exposes token endpoint** (centralized): the App backend holds the private key and issues IATs to trusted callers.

### JWT template (both patterns)
- Header: `alg: RS256`, `typ: JWT`
- Payload: `iss: <app_id>`, `iat: now-60`, `exp: now+540` (<=10 minutes)
- Sign with the App private key (PEM).

### Installation access token request
- `POST https://api.github.com/app/installations/{installation_id}/access_tokens`
- Header: `Authorization: Bearer <jwt>`; `Accept: application/vnd.github+json`
- Response JSON: `token`, `expires_at`
- Git remote format: `https://x-access-token:<token>@github.com/<owner>/<repo>.git`

## Minimal backend sketch (if centralizing token issuance)
- Provide `/token` that:
  - Authenticates caller (e.g., shared secret, mTLS, or OIDC from your infra).
  - Builds JWT with the App private key.
  - Calls the installation access token endpoint.
  - Returns `token` and `expires_at`.
- Provide `/webhook` that:
  - Verifies signature `X-Hub-Signature-256`.
  - Listens to `pull_request`, `check_suite`, `check_run`, `status`.
  - Optionally records state for observability or triggers retries in the client.

### FastAPI-style skeleton
```python
import hmac, hashlib, time, jwt, requests
from fastapi import FastAPI, Header, Request, HTTPException

APP_ID = "<app-id>"
INSTALLATION_ID = "<installation-id>"
PRIVATE_KEY = open("app-private-key.pem", "r").read()
WEBHOOK_SECRET = "<webhook-secret>"

app = FastAPI()

def make_jwt():
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 9 * 60, "iss": APP_ID}
    return jwt.encode(payload, PRIVATE_KEY, algorithm="RS256")

def get_installation_token():
    r = requests.post(
        f"https://api.github.com/app/installations/{INSTALLATION_ID}/access_tokens",
        headers={"Authorization": f"Bearer {make_jwt()}", "Accept": "application/vnd.github+json"},
        timeout=20,
    )
    r.raise_for_status()
    return r.json()

def verify_signature(secret, signature, body):
    mac = hmac.new(secret.encode(), msg=body, digestmod=hashlib.sha256)
    return hmac.compare_digest("sha256=" + mac.hexdigest(), signature or "")

@app.post("/token")
async def token_endpoint():
    # Add real auth here (API key, mTLS, etc.)
    return get_installation_token()

@app.post("/webhook")
async def webhook(x_hub_signature_256: str = Header(None), request: Request = None):
    body = await request.body()
    if not verify_signature(WEBHOOK_SECRET, x_hub_signature_256, body):
        raise HTTPException(status_code=401, detail="invalid signature")
    event = request.headers.get("X-GitHub-Event", "")
    payload = await request.json()
    # Record or react to pull_request/check_run/check_suite/status events
    return {"ok": True}
```

## What the App enables the Python client to do
- Obtain an installation token (either directly or via `/token`).
- Use that token to:
  - Clone/fetch via HTTPS.
  - Create branches and push (CI needs in-repo branches).
  - Call REST APIs to open PRs and monitor CI.
- No personal tokens are used; all actions are under the App’s installation.

## Expectations for the Python client (paired behavior)
- Follow the repo guardrails (one theorem file, correct path, branch prefix `add-theorem-`, no protected files).
- Open PRs from in-repo branches (not forks) so CI can push regenerated `Init.lean`.
- Poll combined status or checks API until CI completes; retry on failures.

## Building and running the App
- Language/runtime: any HTTP-capable backend (Python shown above).
- Store secrets securely (e.g., env vars + secret manager).
- Run with HTTPS (TLS termination in front) and protect `/token`.
- Keep JWT lifetime short (<=10 minutes); refresh IATs per job or when near expiry.
- Use a durable store (optional) if you want to track webhook state for observability and retry decisions.

## Security notes
- Protect the App private key and webhook secret; never ship them to clients unless you intentionally choose the “client holds key” model.
- If exposing `/token`, authenticate and rate-limit callers; log issuance events.
- Verify all webhooks with `X-Hub-Signature-256`.

With this document, you can implement the GitHub App (and optional backend service) that issues installation tokens and observes PR/CI events, enabling the Python proof-generation system to author theorem PRs within the repository’s guardrails.

