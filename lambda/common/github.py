"""
GitHub App authentication + Just-In-Time (JIT) runner registration helpers.

Design notes
------------
* We never use a long-lived Personal Access Token (PAT). The control plane
  authenticates as a **GitHub App**, mints a short-lived (10 min) JWT from the
  app private key, exchanges it for an **installation access token** (valid 1h),
  and uses that to request a **JIT runner config** that is single-use and tied
  to one ephemeral runner.
* The JIT config (`encoded_jit_config`) is what the runner consumes with
  `./run.sh --jitconfig <value>`. It cannot be reused: once the runner comes
  online and finishes its single job it deregisters automatically.
* Only the standard library is required *except* PyJWT (+cryptography) for RS256
  signing. Those are vendored into the deployment package / layer.
"""

import json
import os
import time
import urllib.error
import urllib.request

import jwt  # PyJWT, bundled in the deployment package

# Defaults to public GitHub. For a fully-private deployment set GITHUB_API_URL
# to your in-VPC GitHub Enterprise Server API, e.g. https://ghe.internal/api/v3.
GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
_USER_AGENT = "ecs-gha-runner-control-plane"


def _request(method, url, token=None, token_scheme="token", body=None, timeout=10):
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": _USER_AGENT,
    }
    if token:
        headers["Authorization"] = f"{token_scheme} {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read().decode("utf-8")
            return resp.status, (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API {method} {url} failed: {exc.code} {detail}") from exc


def build_app_jwt(app_id: str, private_key_pem: str) -> str:
    """RS256-signed JWT used to authenticate *as the App* (not an installation)."""
    now = int(time.time())
    claims = {
        "iat": now - 60,        # allow for clock drift
        "exp": now + 9 * 60,    # max allowed is 10 min
        "iss": app_id,
    }
    return jwt.encode(claims, private_key_pem, algorithm="RS256")


def installation_token(app_jwt: str, installation_id: int) -> str:
    """Exchange the App JWT for a short-lived installation access token."""
    url = f"{GITHUB_API}/app/installations/{installation_id}/access_tokens"
    status, body = _request("POST", url, token=app_jwt, token_scheme="Bearer")
    return body["token"]


def generate_jit_config(
    inst_token: str,
    owner: str,
    repo: str,
    runner_name: str,
    labels,
    runner_group_id: int = 1,
    work_folder: str = "_work",
):
    """
    Request a single-use JIT runner registration config (repo-scoped).

    For an org-wide runner group, swap the URL for:
        /orgs/{org}/actions/runners/generate-jitconfig
    """
    url = f"{GITHUB_API}/repos/{owner}/{repo}/actions/runners/generate-jitconfig"
    body = {
        "name": runner_name,
        "runner_group_id": runner_group_id,
        "labels": list(labels),
        "work_folder": work_folder,
    }
    status, payload = _request("POST", url, token=inst_token, body=body)
    return payload["encoded_jit_config"]
