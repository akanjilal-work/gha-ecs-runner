# syntax=docker/dockerfile:1
#
# Ephemeral GitHub Actions runner for ECS Fargate.
#
# Build engine: rootless BuildKit (no Docker daemon, no --privileged), which is
# the constraint Fargate imposes. Images are pushed straight to ECR using the
# Amazon ECR credential helper, which transparently uses the ECS *task role* --
# so there are no static registry credentials anywhere in the pipeline.
#
# NO-PUBLIC BUILD: in a private environment, build this image in a controlled
# pipeline where:
#   * BASE_REGISTRY points at your ECR pull-through cache, so the base image is
#     pulled privately (default below is the public path for convenience only).
#   * TOOL_MIRROR points at an internal artifact mirror (S3 / CodeArtifact /
#     Artifactory) holding the awscli, buildkit, ecr-helper, cosign and syft
#     archives, instead of fetching them from the public internet.
# The running runner needs zero internet; only this build step touches mirrors.

ARG BASE_REGISTRY=public.ecr.aws
FROM ${BASE_REGISTRY}/ubuntu/ubuntu:22.04

# Internal mirror base URLs (override in a no-public pipeline).
ARG TOOL_MIRROR_AWSCLI=https://awscli.amazonaws.com
ARG TOOL_MIRROR_ECR_HELPER=https://amazon-ecr-credential-helper-releases.s3.us-east-2.amazonaws.com
ARG TOOL_MIRROR_GITHUB=https://github.com

ARG RUNNER_VERSION=2.335.1
ARG BUILDKIT_VERSION=v0.15.2
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=0 \
    RUNNER_MANUALLY_TRAP_SIG=1

# --- base packages -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq git unzip tar gnupg uidmap \
        libicu70 libssl3 \
    && rm -rf /var/lib/apt/lists/*

# --- AWS CLI v2 --------------------------------------------------------------
RUN curl -fsSL "${TOOL_MIRROR_AWSCLI}/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# --- Amazon ECR credential helper (task-role based auth, no static creds) -----
RUN curl -fsSL -o /usr/local/bin/docker-credential-ecr-login \
        "${TOOL_MIRROR_ECR_HELPER}/0.9.0/linux-amd64/docker-credential-ecr-login" \
    && chmod +x /usr/local/bin/docker-credential-ecr-login

# --- rootless BuildKit (daemonless container builds) -------------------------
RUN curl -fsSL "${TOOL_MIRROR_GITHUB}/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-${TARGETARCH}.tar.gz" \
        | tar -xz -C /usr/local

# --- supply-chain tooling: SBOM (syft) + signing (cosign) --------------------
RUN curl -fsSL "${TOOL_MIRROR_GITHUB}/anchore/syft/releases/download/v1.14.0/syft_1.14.0_linux_amd64.tar.gz" \
        | tar -xz -C /usr/local/bin syft \
    && curl -fsSL -o /usr/local/bin/cosign \
        "${TOOL_MIRROR_GITHUB}/sigstore/cosign/releases/download/v2.4.0/cosign-linux-amd64" \
    && chmod +x /usr/local/bin/cosign

# --- non-root runner user ----------------------------------------------------
# subuid/subgid ranges are required for rootless BuildKit's user namespace
# (rootlesskit + newuidmap). Without them buildkitd fails to start on Fargate.
RUN useradd -m -u 1000 -s /bin/bash runner \
    && echo "runner:100000:65536" > /etc/subuid \
    && echo "runner:100000:65536" > /etc/subgid
USER runner
WORKDIR /home/runner

# --- GitHub Actions runner ---------------------------------------------------
RUN curl -fsSL -o runner.tar.gz \
        "${TOOL_MIRROR_GITHUB}/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && tar xzf runner.tar.gz \
    && rm runner.tar.gz

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

# Tell BuildKit/buildctl to authenticate to any *.dkr.ecr.* registry via the
# ECR credential helper, which reads the task-role credentials from the
# container credentials endpoint at runtime.
RUN mkdir -p /home/runner/.docker \
    && printf '{ "credsStore": "", "credHelpers": { "public.ecr.aws": "ecr-login" } }\n' \
        > /home/runner/.docker/config.json

ENTRYPOINT ["/home/runner/entrypoint.sh"]
