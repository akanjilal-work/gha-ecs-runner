#!/usr/bin/env bash
# Stage the control-API package (handler + PyJWT/cryptography) for Terraform.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
B="$HERE/build"
rm -rf "$B"; mkdir -p "$B"
cp "$HERE/handler.py" "$B/"
python3 -m pip install PyJWT==2.9.0 cryptography==43.0.1 -t "$B" \
  --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 \
  --only-binary=:all: --upgrade -q
echo "staged $B"
