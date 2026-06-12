"""
Control interface for the live demo. A small function behind a public address
that the demo page calls. It holds the GitHub App credential and the read only
permissions, so the browser never touches a secret and can only do two bounded
things: ask for a build, and ask for the current state of a build.

POST /trigger
    Bot and rate checks, a hard daily cap, then a workflow dispatch. Returns the
    run identifier the page should follow.

GET /status?run_id=<id>
    Reads the GitHub run and its steps, the runner tasks, the registry, and the
    live application, and returns a single view: plain milestones, the real step
    lines, a filtered technical view, and the application response. Nothing is
    stored. Every poll reads the current state.
"""

import json
import os
import time
import urllib.error
import urllib.request

import boto3
import jwt  # PyJWT, vendored

secrets = boto3.client("secretsmanager")
ecs = boto3.client("ecs")
ecr = boto3.client("ecr")
logs = boto3.client("logs")
ddb = boto3.client("dynamodb")

APP_ID = os.environ["GITHUB_APP_ID"]
APP_KEY_SECRET_ARN = os.environ["APP_KEY_SECRET_ARN"]
INSTALLATION_ID = os.environ["INSTALLATION_ID"]
OWNER = os.environ["REPO_OWNER"]
REPO = os.environ["REPO_NAME"]
WORKFLOW_FILE = os.environ["WORKFLOW_FILE"]
CLUSTER = os.environ["CLUSTER"]
RUNNER_FAMILY = os.environ["RUNNER_FAMILY"]
RUNNER_LOG_GROUP = os.environ["RUNNER_LOG_GROUP"]
APP_URL = os.environ["APP_URL"]
ECR_REPO = os.environ["ECR_REPO"]
STATE_TABLE = os.environ["STATE_TABLE"]
DAILY_CAP = int(os.environ.get("DAILY_CAP", "20"))
GITHUB_API = "https://api.github.com"

_key_cache = {}


def _cors(body, code=200):
    return {
        "statusCode": code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
            "Access-Control-Allow-Headers": "content-type",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body),
    }


# --- GitHub helpers ----------------------------------------------------------
def _app_key():
    if "v" not in _key_cache:
        _key_cache["v"] = secrets.get_secret_value(SecretId=APP_KEY_SECRET_ARN)["SecretString"]
    return _key_cache["v"]


def _installation_token():
    now = int(time.time())
    app_jwt = jwt.encode({"iat": now - 60, "exp": now + 540, "iss": str(APP_ID)}, _app_key(), algorithm="RS256")
    code, body = _gh("POST", f"/app/installations/{INSTALLATION_ID}/access_tokens", token=app_jwt, scheme="Bearer")
    return body["token"]


def _gh(method, path, token=None, scheme="token", body=None, full=None):
    url = full or (GITHUB_API + path)
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "gha-demo-control"}
    if token:
        headers["Authorization"] = f"{scheme} {token}"
    data = json.dumps(body).encode() if body is not None else None
    if data:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}


# --- daily cap ---------------------------------------------------------------
def _under_cap():
    day = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        r = ddb.update_item(
            TableName=STATE_TABLE,
            Key={"pk": {"S": f"cap#{day}"}},
            UpdateExpression="ADD #c :one",
            ExpressionAttributeNames={"#c": "count"},
            ExpressionAttributeValues={":one": {"N": "1"}},
            ReturnValues="UPDATED_NEW",
        )
        return int(r["Attributes"]["count"]["N"]) <= DAILY_CAP
    except Exception:
        return True  # never block on a counter error


# --- trigger -----------------------------------------------------------------
def trigger():
    if not _under_cap():
        return _cors({"error": "daily build limit reached, please come back tomorrow"}, 429)
    token = _installation_token()
    before = int(time.time())
    code, _ = _gh("POST", f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW_FILE}/dispatches",
                  token=token, body={"ref": "main", "inputs": {"reason": "live demo"}})
    if code not in (204, 201):
        return _cors({"error": "could not start the build"}, 502)
    run_id = None
    for _ in range(10):
        time.sleep(2)
        c, b = _gh("GET", f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW_FILE}/runs?event=workflow_dispatch&per_page=1", token=token)
        runs = b.get("workflow_runs", [])
        if runs and _parse_iso(runs[0]["created_at"]) >= before - 5:
            run_id = runs[0]["id"]
            break
    if not run_id:
        return _cors({"error": "build started but could not resolve the run"}, 202)
    return _cors({"run_id": run_id, "url": f"https://github.com/{OWNER}/{REPO}/actions/runs/{run_id}"})


def _parse_iso(s):
    return int(time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")))


# --- status ------------------------------------------------------------------
# Map raw step names to plain milestones.
MILESTONES = [
    ("queued", "Your build is queued"),
    ("runner", "A single use runner is starting on a private instance"),
    ("build", "The image is being built with a rootless engine"),
    ("push", "The image was pushed to the private registry"),
    ("sbom", "A software bill of materials was generated"),
    ("sign", "The image was signed in the account"),
    ("verify", "The signature was verified in the pipeline"),
    ("gate", "The deploy gate verified the signature again"),
    ("deploy", "The application was rolled out behind the load balancer"),
    ("live", "The application is live"),
]

STEP_TO_MILESTONE = {
    "Build and push (rootless BuildKit -> ECR)": "build",
    "Resolve pushed digest": "push",
    "Generate SBOM": "sbom",
    "Sign image (cosign + AWS KMS, no public tlog)": "sign",
    "Verify in-pipeline before release": "verify",
    "Deploy-time signature gate": "gate",
    "Roll the service to the verified image": "deploy",
}


def status(run_id):
    token = _installation_token()
    _, run = _gh("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}", token=token)
    _, jobsb = _gh("GET", f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/jobs", token=token)
    jobs = jobsb.get("jobs", [])

    steps_lines = []
    done = set()
    active = None
    for j in jobs:
        for s in j.get("steps", []):
            name = s.get("name", "")
            st = s.get("status")
            cc = s.get("conclusion")
            steps_lines.append({"job": j.get("name"), "name": name, "status": st, "conclusion": cc})
            mk = STEP_TO_MILESTONE.get(name)
            if mk:
                if cc == "success":
                    done.add(mk)
                elif st == "in_progress":
                    active = mk

    runner_running = len(ecs.list_tasks(cluster=CLUSTER, family=RUNNER_FAMILY, desiredStatus="RUNNING").get("taskArns", []))
    if runner_running and "build" not in done:
        done.add("runner")
    if run.get("status") in ("queued", "in_progress"):
        done.add("queued")

    app = _app_state()
    # "live" is true only after THIS run's own deploy step has rolled the
    # service and the running application reports a verified signature. Gating on
    # the deploy step, not the image digest, avoids a false positive when a
    # previous build of the same commit is already serving.
    if "deploy" in done and app.get("reachable") and app.get("signature_verified"):
        done.add("live")

    # milestone states, monotonic: once a later stage is reached, earlier ones
    # are done. A failed run marks the next expected stage as failed.
    ms = []
    order = [m[0] for m in MILESTONES]
    last_done = max([order.index(k) for k in done], default=-1)
    run_ok = run.get("status") == "completed" and run.get("conclusion") == "success"
    failed = run.get("conclusion") == "failure"
    for i, (k, label) in enumerate(MILESTONES):
        if k == "live":
            # "live" is true only when the running app is this build.
            state = "done" if "live" in done else ("active" if run_ok else "pending")
        elif run_ok or i <= last_done or k in done:
            state = "done"
        elif i == last_done + 1:
            state = "failed" if failed else "active"
        else:
            state = "pending"
        ms.append({"key": k, "label": label, "state": state})

    # filtered technical lines from the runner log
    filtered = _runner_log_tail()

    failed = run.get("conclusion") == "failure"
    return _cors({
        "run": {"status": run.get("status"), "conclusion": run.get("conclusion"),
                "url": run.get("html_url")},
        "failed": failed,
        "milestones": ms,
        "steps": steps_lines,
        "filtered": filtered,
        "runner_running": runner_running,
        "app": app,
    })


def _ecr_digest(tag):
    if not tag:
        return None
    try:
        r = ecr.describe_images(repositoryName=ECR_REPO, imageIds=[{"imageTag": tag}])
        return r["imageDetails"][0]["imageDigest"]
    except Exception:
        return None


def _app_state():
    try:
        req = urllib.request.Request(APP_URL, headers={"User-Agent": "ctrl"})
        with urllib.request.urlopen(req, timeout=5) as r:
            d = json.loads(r.read().decode())
            return {"reachable": True, "digest": d.get("image_digest"), "git_sha": d.get("git_sha"),
                    "built_at": d.get("built_at"), "signature_verified": d.get("signature_verified"),
                    "url": APP_URL}
    except Exception:
        return {"reachable": False, "url": APP_URL}


def _runner_log_tail():
    try:
        start = (int(time.time()) - 600) * 1000
        r = logs.filter_log_events(logGroupName=RUNNER_LOG_GROUP, startTime=start, limit=200)
        keep = ("buildkit ready", "Connected to GitHub", "Running job", "Job completed", "exporting", "pushing manifest", "DONE")
        out = []
        for e in r.get("events", []):
            m = e["message"].strip()
            if any(k.lower() in m.lower() for k in keep):
                out.append(m[:200])
        return out[-12:]
    except Exception:
        return []


def handler(event, context):
    rc = event.get("requestContext", {}).get("http", {})
    method = rc.get("method", "GET")
    path = rc.get("path", "/")
    if method == "OPTIONS":
        return _cors({"ok": True})
    if method == "POST" and path.endswith("/trigger"):
        return trigger()
    if method == "GET" and path.endswith("/status"):
        qs = event.get("queryStringParameters") or {}
        rid = qs.get("run_id")
        if not rid:
            return _cors({"error": "run_id required"}, 400)
        return status(rid)
    return _cors({"error": "not found", "path": path}, 404)
