# Managed GitHub Actions Runners on AWS ECS → Private Builds → ECR

Self-hosted GitHub Actions runners that run as **ephemeral AWS Fargate tasks**, build container images **daemonlessly** (rootless BuildKit), and push them to **Amazon ECR** — with ECR locked down so the runner is the *only* identity allowed to push. One task = one job = one artifact, then it vanishes.

> Full architecture, security model, and operations playbook: **[`docs/solution-design.md`](docs/solution-design.md)**.

## What this gives you

- **Managed runners** — no EC2 to patch; AWS owns the substrate.
- **Ephemeral & isolated** — single-use JIT runners, one job each, microVM-isolated, rootless build engine.
- **Private-build enforcement** — ECR repo policy + deny means only the runner task role can push; deploy targets pull-only and verify signatures.
- **No public exposure** — private subnets with **egress capped to the VPC CIDR**, all AWS access over **account-scoped VPC endpoints**, a **private REST API** webhook (no public URL), **GitHub Enterprise Server in-VPC** as the event source, and base images via a **private ECR pull-through cache**. No NAT, no internet.
- **In-account image signing** — every image is signed with an **AWS KMS key** via cosign with the **transparency log disabled** (no public Sigstore), verified in-pipeline and at deploy time.
- **No long-lived secrets** — GitHub App (not PAT), JIT registration (no reusable token), task-role ECR auth (no static registry creds).
- **Supply chain** — scan-on-push + Inspector, SBOM (syft), KMS-signed attestations.
- **Ops built in** — SQS+DLQ, reserved-concurrency cost cap, alarms, dashboard, lifecycle policies.

## Architecture in one line

`workflow_job webhook → API Gateway → Webhook Lambda (verify+enqueue) → SQS → Scale-up Lambda (JIT + RunTask) → Fargate runner (build+push) → ECR`

See the diagrams in the design doc.

## Repo layout

```
.
├── docs/solution-design.md        # the detailed design (read this)
├── terraform/                     # full IaC: VPC endpoints, ECR, ECS, IAM,
│   ├── 00-providers.tf            #   KMS, Secrets, SQS, Lambdas, API GW, alarms
│   ├── 01-variables.tf
│   ├── 10-kms-secrets.tf
│   ├── 20-network.tf
│   ├── 30-ecr.tf
│   ├── 40-iam.tf
│   ├── 50-ecs.tf
│   ├── 60-queue-lambda-apigw.tf
│   ├── 70-monitoring.tf
│   └── 99-outputs.tf
├── lambda/
│   ├── webhook/handler.py         # verify HMAC, filter, enqueue
│   ├── scale_up/handler.py        # JIT config + RunTask (partial-batch)
│   ├── common/github.py           # GitHub App JWT / installation token / JIT
│   └── requirements.txt
├── runner/
│   ├── Dockerfile                 # runner + rootless BuildKit + ECR helper + cosign/syft
│   └── entrypoint.sh              # ECR auth, start buildkitd, run one job
├── workflows/build-and-push.yml   # sample consumer workflow
└── Makefile
```

## Prerequisites

- AWS account with an existing VPC + **private** subnets (no IGW/NAT route), Terraform ≥ 1.6, Docker, AWS CLI.
- **GitHub Enterprise Server reachable inside the VPC** (or GitHub Enterprise Cloud + PrivateLink) for a true no-public deployment. You can demo against GitHub.com first, but the webhook ingress is then public — see the design doc §5.1.

## Deploy (demo walkthrough)

### 1. Create the GitHub App (on your GHES)
Settings → Developer settings → GitHub Apps → New.
- **Permissions:** Repository → *Actions* (Read & write), *Administration* (Read & write).
- **Subscribe to events:** *Workflow job*.
- **Webhook:** leave URL blank for now; set a strong **webhook secret**.
- Generate a **private key** (`app.pem`). Note the **App ID**; install it and note the **Installation ID**.

### 2. Stage Lambda packages
```bash
make lambdas        # assembles ./build/webhook and ./build/scale_up (vendors PyJWT)
```

### 3. Apply infrastructure
```bash
cd terraform
terraform init
terraform apply \
  -var='vpc_id=vpc-xxxx' \
  -var='vpc_cidr=10.0.0.0/16' \
  -var='private_subnet_ids=["subnet-aaa","subnet-bbb"]' \
  -var='github_app_id=123456' \
  -var='github_api_url=https://ghe.internal.example/api/v3' \
  -var='runner_image_uri=PLACEHOLDER'   # set real value after step 5
```
Grab the outputs: `webhook_url` (a **private** URL, resolvable only inside the VPC), `signing_kms_uri`, `webhook_secret_arn`, `github_app_key_secret_arn`, `ecr_runner_repository_url`, `ecr_app_repository_url`.

### 4. Load the GitHub App private key (never goes into Terraform state)
```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw github_app_key_secret_arn)" \
  --secret-string file://app.pem
```

### 5. Build & push the runner image, then re-apply with its URI
```bash
make runner-image RUNNER_REPO="$(terraform -chdir=terraform output -raw ecr_runner_repository_url)"
terraform apply -var='runner_image_uri=<that-repo>:latest' ...   # plus the vars from step 3
```

### 6. Wire the webhook back to GitHub
In the GitHub App settings, set **Webhook URL** to the `webhook_url` output and the **webhook secret** to the value in `webhook_secret_arn`:
```bash
aws secretsmanager get-secret-value --secret-id "$(terraform output -raw webhook_secret_arn)" --query SecretString --output text
```

### 7. Run a build
Add [`workflows/build-and-push.yml`](workflows/build-and-push.yml) to a repo as `.github/workflows/build-and-push.yml` (with a `Dockerfile` to build), and open a PR or push to `main`.

**What you'll see:** GHES queues the job → webhook fires over PrivateLink → a Fargate task appears in the ECS console → it pulls its base image from the private pull-through cache, builds with `buildctl`, pushes to ECR, **signs the image with the in-account KMS key (no public Sigstore)**, attaches an SBOM attestation, verifies its own signature, and the task stops. One job, one runner.

### 8. Prove enforcement — only the runner can push
Try to push to the `demo/app` repo as any other principal — it's denied by the repo policy. Only the runner task role can push, which is what makes "all artifacts are built privately on our runners" actually true.

### 9. Prove it's signed — and verify with the in-account key
```bash
cosign verify --insecure-ignore-tlog=true \
  --key "$(terraform -chdir=terraform output -raw signing_kms_uri)" \
  <account>.dkr.ecr.<region>.amazonaws.com/demo/app:<sha>
```
Deploy targets run exactly this check (e.g. sigstore policy-controller / a Notation trust policy) so only KMS-signed, runner-built images are admitted.

### 10. Prove it's private — no public path exists
- The runner & Lambda security groups have **no `0.0.0.0/0` egress** — only the VPC CIDR.
- There is **no NAT gateway / IGW route** on the runner subnets.
- The webhook `webhook_url` is a **private REST API**: it only resolves through the `execute-api` VPC endpoint; calling it from outside the VPC fails.
- All `ecr/kms/secretsmanager/sqs/sts/logs` calls resolve to **VPC endpoint** private IPs (check with `nslookup` from inside the VPC), and the endpoint policies reject any non-account principal.

## Build-engine & signing alternatives

- **kaniko** (instead of rootless BuildKit): bake `gcr.io/kaniko-project/executor` (mirrored privately) into the runner image and run `/kaniko/executor --dockerfile=Dockerfile --destination=$ECR_HOST/demo/app:$TAG`. ECR auth via the same credential helper.
- **ECS on EC2** (full Docker / privileged / DinD): swap the Fargate capacity provider for an EC2 ASG capacity provider; you then own host patching and isolation. See §11 of the design doc.
- **AWS Signer + Notation** (instead of cosign+KMS): managed in-account signing profile, verified with a Notation trust policy. Same no-public guarantee; see §7.6.

## Notes & honesty

This is a **reference implementation** meant to showcase the design end-to-end. Rootless BuildKit on Fargate (the `--oci-worker-no-process-sandbox` path) and exact runner/cosign versions typically need small environment-specific tuning before a clean first green build — that's expected and called out in the runner files. The Terraform is reference-grade (`terraform validate`/`plan` against your account before relying on it) and assumes you bring an existing VPC with private subnets.
