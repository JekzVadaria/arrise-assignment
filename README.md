# ARRISE DevOps Assignment

| Task | Deliverable | Where |
|---|---|---|
| 1. Multi-instance EC2 | Terraform | [`modules/ec2-fleet`](modules/ec2-fleet), [`stacks/ec2-fleet`](stacks/ec2-fleet), answer in [Task 1](#task-1--multi-instance-ec2-provisioning) |
| 2.1 Remote state and locking | Terraform | [`bootstrap/state-backend`](bootstrap/state-backend), [`stacks/ec2-fleet/backend.tf`](stacks/ec2-fleet/backend.tf) |
| 2.2 Concurrent `apply` explanation | Answer | [Task 2](#task-2--remote-state--locking) |

Account A = `000000000000`, Account B = `111111111111`, Region `eu-west-1`. Resource names and IDs in `terraform.tfvars` are placeholders.

---

## Repository layout

```text
.
├── README.md                        this file: all answers
├── Makefile                         make ci = fmt + validate + tflint + checkov + test
├── .github/workflows/terraform.yml  CI: the same checks, plus an OIDC-based plan on PRs
├── .pre-commit-config.yaml  .tflint.hcl  .checkov.yaml  .terraform-docs.yml
├── bootstrap/state-backend/         Task 2.1: S3 state bucket, DynamoDB lock table, KMS key
├── modules/ec2-fleet/               Task 1: reusable module (+ tests/)
└── stacks/ec2-fleet/                Task 1 root module: 5 instances + S3 backend (+ tests/)
```

```bash
make ci                                                      # all checks, no AWS access needed
terraform -chdir=bootstrap/state-backend init && terraform -chdir=bootstrap/state-backend apply
terraform -chdir=stacks/ec2-fleet init && terraform -chdir=stacks/ec2-fleet apply
```

---

## Task 1 — Multi-Instance EC2 Provisioning

| Requirement | How it is met |
|---|---|
| 5 instances from one variable | `var.instances` (a map) drives `for_each`. There are no per-instance resource blocks. |
| Different type, volume type, size, key pair | A three-tier stack, shown in the table below. Each instance has its own key pair. |
| At least one io1/io2 | **Variable validation** in [`modules/ec2-fleet/variables.tf`](modules/ec2-fleet/variables.tf): `length(setintersection(values(var.instances)[*].root_volume_type, ["io1", "io2"])) > 0`. Satisfied by `db` (io2) and `app-2` (io1). |
| Tags Name, Environment, Owner | Set by the module on every instance and root volume, and merged last so callers cannot override them |
| Lifecycle protection | `db` (see below) |
| Outputs | `instance_ids` (name → ID) and `private_ips` (name → private IP) |

| Instance | Tier | Instance type | Root volume | Size | Key pair | Protected |
|---|---|---|---|---|---|---|
| `arrise-dev-web-1` | web | t3.micro | gp3 | 20 GiB | arrise-dev-web-1 | |
| `arrise-dev-web-2` | web | t3.small | standard | 16 GiB | arrise-dev-web-2 | |
| `arrise-dev-app-1` | app | c5.large | gp2 | 30 GiB | arrise-dev-app-1 | |
| `arrise-dev-app-2` | app | c5.xlarge | **io1** (2000 IOPS) | 40 GiB | arrise-dev-app-2 | |
| `arrise-dev-db` | db | r5.large | **io2** (5000 IOPS) | 100 GiB | arrise-dev-db | **yes** |

Each tier has its own security group (ALB → web → app → db). The servers within a tier differ from each other only because the assignment requires every instance to have a different type, volume and key pair.

**Where each rule is enforced:**
- **The module** (`modules/ec2-fleet/variables.tf`) checks the generic rules: allowed boot volume types, **at least one io1/io2**, IOPS only on io1/io2/gp3, and size limits.
- **The stack** (`stacks/ec2-fleet/variables.tf`) checks the rules specific to this fleet: exactly 5 instances, distinct type/volume type/size/key pair, and exactly one protected instance.

A `terraform.tfvars` that breaks any rule fails at `plan`. Every instance also gets IMDSv2-only metadata, an encrypted root volume and no public IP.

### Which instance is protected, and why

**`arrise-dev-db`.** In a web → app → db stack, the web and app servers are **stateless**. They hold no data, so either one can be destroyed and rebuilt from the AMI in minutes while its twin keeps serving traffic. The database server is the **only stateful instance and has no twin**. Its data lives on its io2 volume, so deleting it means data loss and a full outage of every tier above it.

The risk is not only `terraform destroy`. On `aws_instance`, changing `subnet_id`, `key_name` or `ami` forces a **replacement** (destroy, then create), so a one-line typo in tfvars could silently recreate the database. `prevent_destroy = true` turns that plan into an error.

**Implementation detail:** `lifecycle` arguments must be literal values, so `prevent_destroy` cannot vary per `for_each` key. The module splits the single map into two filtered maps feeding two blocks: `aws_instance.this` and `aws_instance.protected` (with `prevent_destroy = true`).

`prevent_destroy` only guards against Terraform, and it stops applying if someone deletes the resource block. The protected instance therefore also has **EC2 termination protection** (`disable_api_termination = true`, with `force_destroy = false` so the provider can't turn it off), and its root volume is kept on termination (`delete_on_termination = false`).

---

## Task 2 — Remote State & Locking

### 2.1 Backend (Terraform)

- `bootstrap/state-backend` creates the backend and runs once, with local state, because the bucket must exist before anything can use it:
  - **S3 bucket:** versioned, SSE-KMS, Block Public Access, TLS only, `prevent_destroy`.
  - **DynamoDB table:** `LockID` string hash key, point-in-time recovery, deletion protection.
- `stacks/ec2-fleet/backend.tf` uses them: `backend "s3" { bucket, key, region, dynamodb_table, encrypt = true, kms_key_id }`.
- The backend lives in the **root** stack, not the module. Terraform only reads backend configuration from the root module.

### 2.2 What happens today if two people run `apply` at the same time?

With local state, each person's `terraform.tfstate` lives on their own machine, and **nothing coordinates them**.

- **Separate laptops:** person B's state has no record of what person A just created. B's apply creates the same five instances a **second time**, which succeeds silently because EC2 Name tags need not be unique. It fails half-way on resources that must be unique, such as key pairs, or reverts A's changes. The result is duplicate infrastructure, double cost, and state files that disagree with AWS and with each other.
- **A shared state file** (network drive, same CI runner, or committed to Git): both runs start from the same snapshot, change AWS concurrently, then both write the file. **The last write wins**, and the other run's resources still exist in AWS but are no longer tracked (a lost update). Local state locking only works between processes on one machine. Git cannot merge state.

### How the S3 + DynamoDB backend prevents it

1. **Single source of truth:** everyone reads and writes the same state object in S3.
2. **Mutual exclusion:** before `plan` or `apply`, Terraform performs a **conditional write** of a lock item (`LockID = <bucket>/<key>`) to DynamoDB. The write succeeds only if no lock exists, so it is atomic. The second run fails immediately with `Error acquiring the state lock`, showing who holds the lock and since when. With `-lock-timeout=5m` it waits instead.
3. **Ordered updates:** the first run writes the new state, then releases the lock. The second run then starts from the **current** state. Terraform also keeps a state checksum in DynamoDB, so a stale read is detected.
4. **Recovery:** S3 versioning keeps every previous state, so a bad write can be rolled back.

Terraform ≥ 1.10 can lock natively in S3 (`use_lockfile = true`), and ≥ 1.11 marks `dynamodb_table` as deprecated. DynamoDB is used here because the task requires it. To migrate, enable both, then remove `dynamodb_table`.

---

## Verification

These checks ran locally with Terraform 1.14.5 and AWS provider 6.72.0, without AWS credentials. CI runs the same checks, and `make ci` runs them locally.

| Check | Result |
|---|---|
| `terraform fmt -check`, `terraform validate` | clean / valid |
| TFLint (Terraform recommended + AWS ruleset) | 0 issues |
| Checkov | 0 failed. Every skip is inline next to its resource, with a reason. |
| `terraform test` (mocked provider) | 15 passing. The module has 10: protected/unprotected split, tags, IMDSv2/encryption/no public IP, volume settings, key pairs, outputs, and invalid input (including a fleet with no io1/io2 volume). The stack has 5: the committed 2-web/2-app/1-db tfvars meet every Task 1 rule, and each stack rule rejects a violating change. |

