#!/usr/bin/env bash
#
# Ephemeral runner entrypoint.
#  - Configures the ECR credential helper for this account/region so BuildKit
#    can push without static credentials (uses the ECS task role).
#  - Starts rootless buildkitd in the background (no daemon, no privileged).
#  - Runs the GitHub runner with the single-use JIT config. `--ephemeral` is
#    already implied by JIT: the runner takes exactly one job, then exits.
#
# Any non-zero exit here causes the Fargate task to stop, which is the desired
# scale-in behaviour: one runner == one job == one task.

set -euo pipefail

if [[ -z "${ENCODED_JIT_CONFIG:-}" ]]; then
  echo "FATAL: ENCODED_JIT_CONFIG not provided" >&2
  exit 1
fi

# --- region/account-aware ECR auth ------------------------------------------
# The task role's region is exposed to the SDK/helper via AWS_REGION (injected
# by the task definition). Register every ECR registry host with the helper.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_HOST="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

cat > "${HOME}/.docker/config.json" <<EOF
{
  "credHelpers": {
    "${ECR_HOST}": "ecr-login",
    "public.ecr.aws": "ecr-login"
  }
}
EOF
export ECR_HOST   # exported for workflows that want the registry host

# --- rootless BuildKit -------------------------------------------------------
# --oci-worker-no-process-sandbox lets buildkitd run unprivileged inside the
# Fargate container. The socket is what `buildctl --addr` connects to.
export XDG_RUNTIME_DIR="${HOME}/.local/run"
mkdir -p "${XDG_RUNTIME_DIR}"
export BUILDKIT_HOST="unix://${HOME}/buildkitd.sock"
rootlesskit \
  buildkitd \
    --addr "${BUILDKIT_HOST}" \
    --oci-worker-no-process-sandbox \
    >"${HOME}/buildkitd.log" 2>&1 &
BUILDKITD_PID=$!

# Wait for the build daemon to accept connections. If it never comes up, print
# its log so the failure is visible in the task logs rather than silent.
buildkit_ready=0
for _ in $(seq 1 30); do
  if buildctl --addr "${BUILDKIT_HOST}" debug workers >/dev/null 2>&1; then
    buildkit_ready=1
    break
  fi
  sleep 1
done
if [[ "${buildkit_ready}" -ne 1 ]]; then
  echo "FATAL: buildkitd did not become ready. Log follows:" >&2
  cat "${HOME}/buildkitd.log" >&2 || true
  exit 1
fi
echo "buildkitd ready at ${BUILDKIT_HOST}"

cleanup() {
  kill "${BUILDKITD_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# --- run exactly one job -----------------------------------------------------
cd /home/runner
./run.sh --jitconfig "${ENCODED_JIT_CONFIG}"
