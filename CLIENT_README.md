# CLIENT_README — Automating Theorem PRs with a Python GitHub App

This guide describes how an external Python-based proof generation system can author pull requests that add new theorems to this repository using a GitHub App (no personal credentials). It consolidates the repository’s invariants and provides implementation-oriented steps and code snippets.

## Repository guardrails (must comply)
- One theorem per PR; exactly one new `.lean` theorem file is added.
- Theorem files live under `GoedelsPoetryLib/<Category>/.../<Name>.lean`.
- If a filename already exists in that directory, append a monotone suffix: `Name1.lean`, `Name2.lean`, etc.
- Do not touch protected files: `.github/`, `scripts/`, `lakefile.lean`, `lean-toolchain`, `.gitignore`, `README.md`, `CONTRIBUTING.md`, `LICENSE`, `GoedelsPoetryLib/Init.lean`.
- Do not add or edit `Init.lean`; CI regenerates and commits subdirectory `Init.lean` files.
- Branch name for theorem additions must start with `add-theorem-`.
- Append-only: no modifications or deletions of existing theorem files; no overwrites.
- CI will regenerate `Init.lean`, commit, push to the PR branch, rebuild, retest, and auto-merge if green.

## GitHub App ↔ Python service integration
- Store App ID, installation ID, and the App private key (PEM) in the Python service.
- Per run:
  1. Build a short-lived JWT signed with the App key.
  2. Exchange the JWT for an installation access token (IAT): `POST /app/installations/{installation_id}/access_tokens`.
  3. Use the IAT for git and GitHub API calls.
- Remote for git: `https://x-access-token:<token>@github.com/<owner>/<repo>.git`.
- Permissions needed: `contents:write`, `pull_requests:write`, `statuses:read` (or `checks:read`), `metadata:read`.
- Rotate often: JWT valid ≤10 minutes; fetch a fresh IAT per job or near expiry.

### Minimal auth helper (Python)
```python
import time, jwt, requests

APP_ID = "<app-id>"
INSTALLATION_ID = "<installation-id>"
PRIVATE_KEY = open("app-private-key.pem", "r").read()

def make_jwt():
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 9 * 60, "iss": APP_ID}
    return jwt.encode(payload, PRIVATE_KEY, algorithm="RS256")

def get_installation_token():
    jwt_token = make_jwt()
    r = requests.post(
        f"https://api.github.com/app/installations/{INSTALLATION_ID}/access_tokens",
        headers={"Authorization": f"Bearer {jwt_token}", "Accept": "application/vnd.github+json"},
        timeout=20,
    )
    r.raise_for_status()
    data = r.json()
    return data["token"], data["expires_at"]
```

## Expanded end-to-end flow (Python)
1) Generate proof text (Lean).
2) Choose path and filename under `GoedelsPoetryLib/<Category>/.../<Name>.lean`; resolve conflicts with numeric suffixes.
3) Sync base: clone or fetch `origin/main`; `git checkout main`.
4) Create branch: `git checkout -b add-theorem-<slug>` (CI enforces prefix).
5) Write the single theorem file; avoid protected files.
6) Optional local validation: `lake build` (and `lake build Tests`); you may run `python3 scripts/regenerate_init.py` locally, but CI will regenerate and commit `Init.lean` anyway.
7) Commit: stage only the new theorem file (and any locally regenerated `Init.lean` if you chose to run the script); commit message like `feat: add <theorem name>`.
8) Push branch to origin (must be an in-repo branch, not a fork, so CI can push its `Init.lean` updates).
9) Open PR: head = your branch, base = `main`.
10) Monitor CI: wait for status/checks to complete; retry on failure (naming conflicts, syntax errors, append-only violations, or CI push failures).

## Python snippets for key steps

### Open PR
```python
import requests

def open_pr(token, owner, repo, head_branch, title, body=""):
    url = f"https://api.github.com/repos/{owner}/{repo}/pulls"
    r = requests.post(
        url,
        headers={
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github+json",
        },
        json={
            "title": title,
            "head": head_branch,  # e.g., "add-theorem-foo"
            "base": "main",
            "body": body,
            "maintainer_can_modify": True,
        },
        timeout=20,
    )
    r.raise_for_status()
    return r.json()["number"]
```

### Monitor CI via combined status
```python
import time, requests

def wait_for_ci(token, owner, repo, sha, timeout_s=1800, poll_s=10):
    url = f"https://api.github.com/repos/{owner}/{repo}/commits/{sha}/status"
    headers = {"Authorization": f"token {token}", "Accept": "application/vnd.github+json"}
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        r = requests.get(url, headers=headers, timeout=15)
        r.raise_for_status()
        data = r.json()
        state = data["state"]  # "pending" | "success" | "failure" | "error"
        if state in ("success", "failure", "error"):
            return state, data.get("statuses", [])
        time.sleep(poll_s)
    raise TimeoutError("CI did not finish in time")
```

### Monitor CI via checks API (optional)
```python
def wait_for_checks(token, owner, repo, ref, timeout_s=1800, poll_s=10):
    url = f"https://api.github.com/repos/{owner}/{repo}/commits/{ref}/check-runs"
    headers = {"Authorization": f"token {token}", "Accept": "application/vnd.github+json"}
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        r = requests.get(url, headers=headers, timeout=15, params={"per_page": 100})
        r.raise_for_status()
        runs = r.json().get("check_runs", [])
        if runs and all(run["status"] == "completed" for run in runs):
            conclusions = {run["name"]: run["conclusion"] for run in runs}
            return conclusions
        time.sleep(poll_s)
    raise TimeoutError("Checks did not finish in time")
```

### Skeleton orchestrator
```python
def run_once():
    token, _ = get_installation_token()
    owner, repo = "<owner>", "goedels-poetry-lib"
    branch = f"add-theorem-{slug}"
    # git clone/fetch; checkout main; create branch; write file; commit; push...

    pr_number = open_pr(token, owner, repo, branch, f"feat: add {theorem_name}")
    sha = get_branch_head_sha(token, owner, repo, branch)  # implement via GitHub API
    state, details = wait_for_ci(token, owner, repo, sha)
    if state != "success":
        raise RuntimeError(f"CI failed: {state}, {details}")
    # optionally delete branch after auto-merge
```

## Operational safeguards and expectations
- Always refresh tokens before long operations to avoid expiry mid-push.
- Ensure `git status` shows only the new theorem file (and optionally regenerated `Init.lean` if you chose to run it locally).
- If CI fails because it cannot push regenerated `Init.lean`, simply retry; the guardrail intentionally blocks merge in that case.
- Keep branches short-lived; delete remote branches after auto-merge to reduce clutter.
- CI checks enforce branch naming, path restrictions, one-file rule, append-only, and protected-file restrictions. Let CI regenerate and commit `Init.lean`; do not hand-edit it.

With the above, a Python service using a GitHub App can autonomously propose and land new theorems while satisfying this repository’s invariants and CI gatekeeping.

