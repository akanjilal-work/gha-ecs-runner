#!/usr/bin/env python3
"""Point the GitHub App webhook at a new address after the environment is rebuilt.

Usage: repoint_webhook.py <webhook_url>
Reads the App private key from Secrets Manager (APP_KEY_SECRET_ARN) and the App
id (GITHUB_APP_ID), mints a short lived App token, and updates the webhook config.
"""
import json
import os
import sys
import time
import urllib.request

import boto3
import jwt

url = sys.argv[1]
key = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["APP_KEY_SECRET_ARN"])["SecretString"]
now = int(time.time())
tok = jwt.encode({"iat": now - 60, "exp": now + 540, "iss": os.environ["GITHUB_APP_ID"]}, key, algorithm="RS256")
req = urllib.request.Request(
    "https://api.github.com/app/hook/config",
    data=json.dumps({"url": url, "content_type": "json"}).encode(),
    headers={"Authorization": "Bearer " + tok, "Accept": "application/vnd.github+json", "User-Agent": "repoint"},
    method="PATCH",
)
with urllib.request.urlopen(req) as r:
    print("webhook config set:", r.status, url)
