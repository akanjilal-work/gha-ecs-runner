# Build helpers for the control-plane Lambdas and the runner image.
# Lambda packages are assembled under ./build so Terraform's archive_file can zip them.

REGION        ?= us-east-1
RUNNER_REPO   ?= # e.g. 1234567890.dkr.ecr.us-east-1.amazonaws.com/gha-ecs-runner/runner
RUNNER_TAG    ?= latest

.PHONY: lambdas runner-image clean

lambdas:
	rm -rf build && mkdir -p build/webhook build/scale_up
	# webhook: stdlib + boto3 only, no extra deps to vendor
	cp lambda/webhook/handler.py build/webhook/
	# scale_up: handler + shared github helper + PyJWT/cryptography
	cp lambda/scale_up/handler.py build/scale_up/
	cp -r lambda/common build/scale_up/common
	pip install -r lambda/requirements.txt -t build/scale_up \
		--platform manylinux2014_x86_64 --implementation cp --python-version 3.12 \
		--only-binary=:all: --upgrade
	@echo "Lambda packages staged under ./build"

runner-image:
	@test -n "$(RUNNER_REPO)" || (echo "Set RUNNER_REPO=<ecr-uri>"; exit 1)
	aws ecr get-login-password --region $(REGION) \
		| docker login --username AWS --password-stdin $(firstword $(subst /, ,$(RUNNER_REPO)))
	docker build -t $(RUNNER_REPO):$(RUNNER_TAG) runner/
	docker push $(RUNNER_REPO):$(RUNNER_TAG)

clean:
	rm -rf build
