# ECS Fargate + Dynatrace OneAgent (Terraform)

Provision an **AWS ECS Fargate** service and automatically instrument it with the
**Dynatrace OneAgent** — with no custom application image and no manual steps. You supply
a cluster name plus your AWS and Dynatrace credentials; Terraform (run locally or by
GitHub Actions) does the rest.

The running workload is a stock `nginx:alpine` container used as a demonstration target.
To monitor your own app, change one image reference (see [Monitoring your own app](#monitoring-your-own-app)).

---

## How it works (the big picture)

Dynatrace's documented "runtime injection" method for Fargate uses **two containers in one
task**, sharing a volume:

```
┌──────────────────────── ECS Task ────────────────────────┐
│                                                           │
│  1) dynatrace-oneagent-init   (alpine, essential=false)   │
│     • downloads the OneAgent (musl build) from Dynatrace  │
│     • unzips it into the shared "oneagent" volume         │
│     • runs to completion, then exits                      │
│                        │ writes                           │
│              ┌─────────▼──────────┐                       │
│              │  shared volume     │  /opt/dynatrace/oneagent
│              └─────────▲──────────┘                       │
│                        │ reads (read-only)                │
│  2) app   (nginx:alpine, essential=true)                  │
│     • waits for init via dependsOn: COMPLETE              │
│     • LD_PRELOAD loads liboneagentproc.so                 │
│     • DT_TENANT / DT_TENANTTOKEN / DT_CONNECTION_POINT     │
│       tell the agent where to report                      │
└───────────────────────────────────────────────────────────┘
```

Because the agent is preloaded into the process, **the app image needs nothing baked in**.
The connection values are fetched automatically from the Dynatrace `connectioninfo` API at
plan time (see `dynatrace.tf`), so you don't pass them by hand.

Reference: [Dynatrace — Monitor AWS Fargate](https://docs.dynatrace.com/docs/ingest-from/amazon-web-services/integrate-into-aws/aws-fargate).

### What gets created

| Resource | File | Purpose |
|---|---|---|
| ECS cluster | `ecs.tf` | **Looked up, not created** — `data "aws_ecs_cluster"` on `var.cluster_name`; must already exist |
| ECS task definition (2 containers) | `ecs.tf` | OneAgent init + app |
| ECS service (Fargate, public IP) | `ecs.tf` | Keeps 1 task running |
| Execution + task IAM roles | `ecs.tf` | Pull images, read SSM, write logs |
| Security group (port 80) | `ecs.tf` | Inbound HTTP |
| CloudWatch log group | `ecs.tf` | Container logs (7-day retention) |
| SSM SecureString params | `secrets.tf` | PaaS token + tenant token |
| Dynatrace connectioninfo lookup | `dynatrace.tf` | Auto-fills DT_TENANT / token / endpoint |

---

## Prerequisites

- An **existing ECS cluster** whose name you pass as `cluster_name` (this config deploys
  into it; it does not create the cluster).
- **Terraform** >= 1.0 and **AWS credentials** with permission to manage ECS, IAM, SSM,
  CloudWatch, S3, and DynamoDB.
- A **Dynatrace environment** with:
  - the **environment API URL**, e.g. `https://abc12345.live.dynatrace.com`
  - a **PaaS token** (Dynatrace → *Deploy Dynatrace → PaaS integration*). Used to download
    the agent and to look up connection info.

---

## One-time setup: remote state backend

Terraform state is stored remotely in **S3** (with a **DynamoDB** lock) so local runs and
CI share the same state and never collide. Create the bucket + table **once per account**:

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=<globally-unique-bucket-name>"
# note the outputs: state_bucket_name and lock_table_name
```

Then create your backend config for the main project:

```bash
cd ..                       # into terraform/
cp backend.hcl.example backend.hcl
# edit backend.hcl: set bucket + dynamodb_table to the values from bootstrap
```

> The `bootstrap/` config uses local state on purpose — it builds the backend that
> everything else depends on. You only run it once.

---

## Deploy locally

```bash
cd terraform
terraform init -backend-config=backend.hcl

cp terraform.tfvars.example terraform.tfvars   # then edit with your values
terraform plan
terraform apply
```

`terraform.tfvars` (never commit it — it holds the PaaS token):

```hcl
aws_region           = "us-east-1"
cluster_name         = "my-fargate-cluster"
dynatrace_api_url    = "https://abc12345.live.dynatrace.com"
dynatrace_paas_token = "dt0c01.XXXX.XXXX"
```

### Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `cluster_name` | yes | — | Name of an **existing** ECS cluster to deploy into; also prefixes resource names |
| `dynatrace_api_url` | yes | — | Dynatrace environment API URL |
| `dynatrace_paas_token` | yes | — | Dynatrace PaaS token (sensitive) |
| `aws_region` | yes | — | AWS region to deploy into |

### Outputs

`ecs_cluster_name`, `ecs_cluster_arn`, `ecs_service_name`, `ecs_task_definition_arn`.

### Verify it worked

- ECS console → your cluster → service → task is `RUNNING`; the `dynatrace-oneagent-init`
  container shows `Exited (0)`.
- Dynatrace → **Hosts/Processes** → your nginx process appears within a few minutes.
- CloudWatch log group `/ecs/<cluster_name>-logs` → `dynatrace-init` stream shows a clean
  download/unzip; `app` stream shows nginx starting.

### Tear down

```bash
terraform destroy
```

---

## Deploy with GitHub Actions

`.github/workflows/deploy.yml` runs `init → fmt -check → validate → plan → apply`. It
triggers on push to `main` under `terraform/**`, or manually via **workflow_dispatch**.

Configure these **repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | AWS auth for the runner |
| `AWS_REGION` | AWS region to deploy into |
| `TF_STATE_BUCKET` | S3 bucket from bootstrap |
| `TF_LOCK_TABLE` | DynamoDB table from bootstrap |
| `ECS_CLUSTER_NAME` | Default cluster name |
| `DYNATRACE_API_URL` | Dynatrace environment URL |
| `DYNATRACE_PAAS_TOKEN` | Dynatrace PaaS token |

`workflow_dispatch` also accepts `ecs_cluster_name`, `aws_region`, and `dynatrace_api_url`
as inputs that override the secrets for a one-off run.

> CI assumes the state bucket/table already exist — run the bootstrap step first.

---

## Monitoring your own app

Swap the `app` container `image` (and `containerPort` if not 80) in `ecs.tf`. Keep the
`LD_PRELOAD`, the three `DT_*` values, the read-only `oneagent` mount, and the
`dependsOn: COMPLETE`. **Match the agent build to your base image:** the installer uses
`flavor=musl` for Alpine (musl libc). If your image is glibc-based (Debian/Ubuntu/RHEL),
change `flavor=musl` back to `flavor=default` in the init container command in `ecs.tf`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| App container crashes with an `LD_PRELOAD` / loader error | Agent build vs. base image libc mismatch — check `flavor` (musl vs default) |
| No data in Dynatrace, but init succeeded | Bad `dynatrace_api_url`/token, or the task can't reach `DT_CONNECTION_POINT` egress |
| `terraform apply` re-creating existing resources | Backend not initialized — run `terraform init -backend-config=backend.hcl` |
| `Error acquiring the state lock` | A previous run didn't release the DynamoDB lock; check the table |
| Init container fails downloading the agent | PaaS token invalid/expired or no outbound network from the task |

---

## Security notes

- Tokens are stored as **SSM SecureString** parameters and injected at launch — never
  written into the task definition in plaintext.
- Remote state is **encrypted** (S3 SSE) and access-locked; treat the bucket as sensitive
  (it contains resolved token material in state).
- The demo security group allows **port 80 from `0.0.0.0/0`** with a **public IP** and no
  load balancer. Tighten the SG / add an ALB before using this for anything real.
