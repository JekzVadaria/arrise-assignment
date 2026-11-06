# ARRISE DevOps Assignment

| Task | Deliverable | Where |
|---|---|---|
| 1. Multi-instance EC2 | Terraform | [`modules/ec2-fleet`](modules/ec2-fleet), [`stacks/ec2-fleet`](stacks/ec2-fleet), answer in [Task 1](#task-1--multi-instance-ec2-provisioning) |

Account A = `000000000000`, Account B = `111111111111`, Region `eu-west-1`. Resource names and IDs in `terraform.tfvars` are placeholders.

---

## Repository layout

```text
.
├── README.md                        this file: all answers
├── Makefile                         make ci = fmt + validate + tflint + checkov + test
├── .github/workflows/terraform.yml  CI: the same checks
├── .pre-commit-config.yaml  .tflint.hcl  .checkov.yaml  .terraform-docs.yml
├── modules/ec2-fleet/               Task 1: reusable module (+ tests/)
└── stacks/ec2-fleet/                Task 1 root module: 5 instances (+ tests/)
```

```bash
make ci                                                      # all checks, no AWS access needed
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

## Verification

These checks ran locally with Terraform 1.14.5 and AWS provider 6.72.0, without AWS credentials. CI runs the same checks, and `make ci` runs them locally.

| Check | Result |
|---|---|
| `terraform fmt -check`, `terraform validate` | clean / valid |
| TFLint (Terraform recommended + AWS ruleset) | 0 issues |
| Checkov | 0 failed. Every skip is inline next to its resource, with a reason. |
| `terraform test` (mocked provider) | 15 passing. The module has 10: protected/unprotected split, tags, IMDSv2/encryption/no public IP, volume settings, key pairs, outputs, and invalid input (including a fleet with no io1/io2 volume). The stack has 5: the committed 2-web/2-app/1-db tfvars meet every Task 1 rule, and each stack rule rejects a violating change. |

