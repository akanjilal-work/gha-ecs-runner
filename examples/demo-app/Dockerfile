# Minimal demo image the sample workflow builds and pushes to ECR.
# Base image is pulled PRIVATELY via the ECR pull-through cache (no public pull):
#   BASE_REGISTRY = <account>.dkr.ecr.<region>.amazonaws.com  (exported as ECR_HOST)
#   ecr-public/...                                            (pull-through prefix)
ARG BASE_REGISTRY
FROM ${BASE_REGISTRY}/ecr-public/docker/library/alpine:3.20
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.revision=$GIT_SHA
RUN echo "built privately on ECS runner: $GIT_SHA" > /built.txt
ENTRYPOINT ["cat", "/built.txt"]
