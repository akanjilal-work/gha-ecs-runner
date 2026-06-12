#!/usr/bin/env bash
# Stage the webhook and scale-up Lambda packages under ./build so Terraform's
# archive_file can zip them. Reuses the reference handlers from ../../../lambda.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../../lambda"
B="$HERE/build"

rm -rf "$B"
mkdir -p "$B/webhook" "$B/scaleup/common"

# webhook: stdlib + boto3 only (boto3 is in the Lambda runtime)
cp "$SRC/webhook/handler.py" "$B/webhook/"

# scaleup: handler + shared github helper + PyJWT/cryptography (manylinux wheels)
cp "$SRC/scale_up/handler.py" "$B/scaleup/"
cp "$SRC/common/github.py" "$B/scaleup/common/"
: > "$B/scaleup/common/__init__.py"
python3 -m pip install -r "$SRC/requirements.txt" -t "$B/scaleup" \
  --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 \
  --only-binary=:all: --upgrade -q

echo "staged: $B/webhook  $B/scaleup"
