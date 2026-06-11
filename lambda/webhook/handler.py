"""
Webhook receiver (front door of the control plane).

Responsibilities
----------------
1. Verify the GitHub webhook HMAC-SHA256 signature against a secret stored in
   Secrets Manager (constant-time compare). Reject anything that fails.
2. Only act on `workflow_job` events with action == "queued".
3. Confirm the job actually targets our self-hosted runner labels (so we never
   spin up capacity for GitHub-hosted jobs).
4. Hand the work off to SQS as fast as possible and return 200. All the slow /
   failure-prone work (GitHub API calls, ECS RunTask) happens in the scale-up
   Lambda, decoupled behind the queue with a DLQ for poison messages.

This function does NO GitHub API calls and needs NO outbound internet, which
keeps the public-facing component tiny and low-risk.
"""

import base64
import hashlib
import hmac
import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs = boto3.client("sqs")
secrets = boto3.client("secretsmanager")

QUEUE_URL = os.environ["JOB_QUEUE_URL"]
WEBHOOK_SECRET_ARN = os.environ["WEBHOOK_SECRET_ARN"]
REQUIRED_LABELS = {
    label.strip().lower()
    for label in os.environ.get("REQUIRED_LABELS", "self-hosted,ecs,linux,x64").split(",")
    if label.strip()
}

_secret_cache = {}


def _webhook_secret() -> bytes:
    if "value" not in _secret_cache:
        resp = secrets.get_secret_value(SecretId=WEBHOOK_SECRET_ARN)
        _secret_cache["value"] = resp["SecretString"].encode("utf-8")
    return _secret_cache["value"]


def _raw_body(event) -> bytes:
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(body)
    return body.encode("utf-8")


def _verify_signature(raw: bytes, signature_header: str) -> bool:
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    expected = hmac.new(_webhook_secret(), raw, hashlib.sha256).hexdigest()
    provided = signature_header.split("=", 1)[1]
    return hmac.compare_digest(expected, provided)


def _response(code, message):
    return {"statusCode": code, "body": json.dumps({"message": message})}


def handler(event, context):
    # API Gateway HTTP API (payload v2) lowercases header keys.
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw = _raw_body(event)

    if not _verify_signature(raw, headers.get("x-hub-signature-256", "")):
        logger.warning("Rejected request: invalid signature")
        return _response(401, "invalid signature")

    github_event = headers.get("x-github-event", "")
    if github_event == "ping":
        return _response(200, "pong")
    if github_event != "workflow_job":
        return _response(202, f"ignored event: {github_event}")

    payload = json.loads(raw)
    action = payload.get("action")
    if action != "queued":
        # in_progress / completed are useful for metrics but require no scaling.
        return _response(202, f"ignored action: {action}")

    job = payload.get("workflow_job", {})
    job_labels = {str(label).lower() for label in job.get("labels", [])}
    if not REQUIRED_LABELS.issubset(job_labels):
        return _response(202, "job does not target our runner labels")

    repo = payload.get("repository", {})
    installation_id = (payload.get("installation") or {}).get("id")

    message = {
        "owner": repo.get("owner", {}).get("login"),
        "repo": repo.get("name"),
        "job_id": job.get("id"),
        "run_id": job.get("run_id"),
        "labels": sorted(job_labels),
        "installation_id": installation_id,
    }

    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
        # Dedupe defensively: GitHub can deliver a webhook more than once.
        MessageAttributes={
            "job_id": {"DataType": "String", "StringValue": str(job.get("id"))}
        },
    )
    logger.info("Enqueued runner request for %s/%s job=%s",
                message["owner"], message["repo"], message["job_id"])
    return _response(202, "runner requested")
