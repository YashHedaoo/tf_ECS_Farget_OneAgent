# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Terraform configuration that provisions an AWS ECS Fargate service and instruments it
with the Dynatrace OneAgent at runtime (no custom application image required). All
Terraform lives in `terraform/`; there is no application source code in this repo — the
running container is stock `nginx:alpine`.

## Commands

All Terraform commands run from the `terraform/` directory. State lives in a remote
**S3 + DynamoDB** backend (partial config), so `init` needs backend values.

```bash
cd terraform

terraform init -backend-config=backend.hcl   # backend.hcl from backend.hcl.example
terraform fmt -recursive                      # CI runs `terraform fmt -check`; failing diffs fail the build
terraform validate                            # add `-backend=false` on init to validate without backend
terraform plan                                # requires the vars below (or terraform.tfvars)
terraform apply
terraform destroy
```

The S3 bucket and DynamoDB lock table must exist before `init`. Create them once with the
local-state config in `terraform/bootstrap/` (`terraform apply -var="state_bucket_name=..."`),
then copy the outputs into `backend.hcl`.

Required variables have no defaults and must be supplied (`cluster_name`,
`dynatrace_api_url`, `dynatrace_paas_token`). Copy `terraform.tfvars.example` to
`terraform.tfvars` for local runs, or pass `-var` flags:

```bash
terraform plan \
  -var="cluster_name=my-cluster" \
  -var="dynatrace_api_url=https://abc12345.live.dynatrace.com" \
  -var="dynatrace_paas_token=dt0c01...."
```

`terraform.tfvars` is not committed — it holds the sensitive PaaS token.

## Architecture

The core design is **runtime OneAgent injection via a shared volume and container
ordering**, all defined in `ecs.tf` in a single task definition with two containers:

1. `dynatrace-oneagent-init` (`essential = false`) — an Alpine container that downloads
   the OneAgent installer from `DT_API_URL` and unzips it into a shared Docker volume
   named `oneagent` mounted at `/opt/dynatrace/oneagent`. It runs to completion.
   The installer uses `flavor=musl` because the app runs on `nginx:alpine` (musl libc) —
   this must match the app's base image or `LD_PRELOAD` fails to load the `.so`.
2. `app` (`essential = true`, `nginx:alpine`) — waits on the init container via
   `dependsOn` with `condition = "COMPLETE"`, mounts the same `oneagent` volume
   read-only, activates the agent via `LD_PRELOAD`, and reports to Dynatrace using
   `DT_TENANT` / `DT_CONNECTION_POINT` (env) and `DT_TENANTTOKEN` (SSM secret).
   Because the volume is shared, the app image needs no Dynatrace baked in.

The `DT_TENANT` / `DT_TENANTTOKEN` / `DT_CONNECTION_POINT` values are **not** passed as
variables — `dynatrace.tf` fetches them at plan time via a `data "http"` call to the
Dynatrace `.../deployment/installer/agent/connectioninfo` API (auth via the PaaS token),
and parses `tenantUUID` / `tenantToken` / `communicationEndpoints` from the JSON. This
requires the `hashicorp/http` provider (see `provider.tf`).

Swapping the workload means changing the `app` container's `image` (and ports) and, if the
new image is glibc-based, changing `flavor=musl` back to `flavor=default`; the
init/injection mechanism otherwise stays the same.

### Secret flow

Neither token appears in the task definition as plaintext. `secrets.tf` writes two SSM
`SecureString` parameters, each injected via `secrets` → `valueFrom`:
- `/dynatrace/paas_token` ← `var.dynatrace_paas_token`, consumed by the **init** container
  as `DT_PAAS_TOKEN`.
- `/dynatrace/tenant_token` ← `local.dt_tenant_token` (from the `dynatrace.tf` http lookup),
  consumed by the **app** container as `DT_TENANTTOKEN`.

`ecs.tf` grants the **execution role** a scoped IAM policy allowing `ssm:GetParameter`/
`ssm:GetParameters` on **both** parameter ARNs, plus the managed
`AmazonECSTaskExecutionRolePolicy`.

Two IAM roles exist: the **execution role** (pulls images, reads the SSM secret, writes
logs) and the **task role** (the app's own runtime permissions, currently minimal).

### Networking

Deploys into the account's **default VPC and all its subnets** (data sources in
`ecs.tf`), not a purpose-built VPC. The service runs with `assign_public_ip = true` and
a security group open on port 80 ingress from `0.0.0.0/0`. There is no load balancer —
tasks are reached directly by public IP.

## CI/CD

`.github/workflows/deploy.yml` runs `init → fmt -check → validate → plan → apply` on
push to `main` under `terraform/**`, and via `workflow_dispatch`. `init` passes the S3
backend values via `-backend-config` flags, so CI and local runs share the same remote
state. Secrets/inputs come from GitHub Actions secrets (`TF_STATE_BUCKET`, `TF_LOCK_TABLE`,
`DYNATRACE_PAAS_TOKEN`, `ECS_CLUSTER_NAME`, `DYNATRACE_API_URL`, AWS credentials). `fmt
-check` failing the build is why running `terraform fmt` before committing matters. CI
assumes the bootstrap bucket/table already exist.
