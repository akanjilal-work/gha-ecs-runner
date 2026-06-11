"""
Scale-up worker (SQS-triggered).

For each queued job it:
  1. Loads the GitHub App private key from Secrets Manager (cached).
  2. Mints an App JWT -> installation token -> single-use JIT runner config.
  3. Launches ONE ephemeral Fargate task that registers with that JIT config,
     runs exactly one job, and self-terminates.

Scale-IN is implicit: ephemeral runners exit on their own, so there is no
scale-down controller to operate. Partial-batch responses ensure that a single
bad message is retried/parked in the DLQ without re-running succeeded ones.
"""

import json
import logging
import os
import time

import boto3

from common import github

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ecs = boto3.client("ecs")
secrets = boto3.client("secretsmanager")

CLUSTER = os.environ["ECS_CLUSTER"]
TASK_DEFINITION = os.environ["TASK_DEFINITION"]
CONTAINER_NAME = os.environ["CONTAINER_NAME"]
SUBNET_IDS = os.environ["SUBNET_IDS"].split(",")
SECURITY_GROUP_IDS = os.environ["SECURITY_GROUP_IDS"].split(",")
RUNNER_GROUP_ID = int(os.environ.get("RUNNER_GROUP_ID", "1"))
APP_ID = os.environ["GITHUB_APP_ID"]
APP_KEY_SECRET_ARN = os.environ["GITHUB_APP_KEY_SECRET_ARN"]
USE_FARGATE_SPOT = os.environ.get("USE_FARGATE_SPOT", "false").lower() == "true"

_key_cache = {}


def _app_private_key() -> str:
    if "value" not in _key_cache:
        resp = secrets.get_secret_value(SecretId=APP_KEY_SECRET_ARN)
        _key_cache["value"] = resp["SecretString"]
    return _key_cache["value"]


def _launch_runner(msg):
    owner, repo = msg["owner"], msg["repo"]
    runner_name = f"ecs-{repo}-{msg['job_id']}-{int(time.time())}"[:64]

    app_jwt = github.build_app_jwt(APP_ID, _app_private_key())
    inst_token = github.installation_token(app_jwt, msg["installation_id"])
    jit_config = github.generate_jit_config(
        inst_token=inst_token,
        owner=owner,
        repo=repo,
        runner_name=runner_name,
        labels=msg["labels"],
        runner_group_id=RUNNER_GROUP_ID,
    )

    run_args = {
        "cluster": CLUSTER,
        "taskDefinition": TASK_DEFINITION,
        "count": 1,
        "networkConfiguration": {
            "awsvpcConfiguration": {
                "subnets": SUBNET_IDS,
                "securityGroups": SECURITY_GROUP_IDS,
                "assignPublicIp": "DISABLED",  # private subnets only
            }
        },
        "overrides": {
            "containerOverrides": [
                {
                    "name": CONTAINER_NAME,
                    # JIT config is single-use & short-lived; passed as an
                    # override env var, never baked into the image or task def.
                    "environment": [
                        {"name": "ENCODED_JIT_CONFIG", "value": jit_config},
                        {"name": "RUNNER_NAME", "value": runner_name},
                    ],
                }
            ]
        },
        "propagateTags": "TASK_DEFINITION",
        "tags": [
            {"key": "github:owner", "value": owner},
            {"key": "github:repo", "value": repo},
            {"key": "github:job_id", "value": str(msg["job_id"])},
        ],
        "enableExecuteCommand": False,  # no ECS Exec into build runners
    }

    if USE_FARGATE_SPOT:
        run_args["capacityProviderStrategy"] = [
            {"capacityProvider": "FARGATE_SPOT", "weight": 4},
            {"capacityProvider": "FARGATE", "weight": 1, "base": 1},
        ]
    else:
        run_args["launchType"] = "FARGATE"

    resp = ecs.run_task(**run_args)
    failures = resp.get("failures", [])
    if failures:
        raise RuntimeError(f"RunTask failures: {failures}")

    task_arn = resp["tasks"][0]["taskArn"]
    logger.info("Launched runner %s for %s/%s job=%s task=%s",
                runner_name, owner, repo, msg["job_id"], task_arn)


def handler(event, context):
    """SQS batch handler with partial-batch failure reporting."""
    failures = []
    for record in event.get("Records", []):
        try:
            _launch_runner(json.loads(record["body"]))
        except Exception:  # noqa: BLE001 - we want to retry any failure
            logger.exception("Failed to launch runner for record %s", record["messageId"])
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
