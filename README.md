# ARRISE DevOps Assignment

| Task | Deliverable | Where |
|---|---|---|
| 1. Multi-instance EC2 | Terraform | [`modules/ec2-fleet`](modules/ec2-fleet), [`stacks/ec2-fleet`](stacks/ec2-fleet), answer in [Task 1](#task-1--multi-instance-ec2-provisioning) |
| 2.1 Remote state and locking | Terraform | [`bootstrap/state-backend`](bootstrap/state-backend), [`stacks/ec2-fleet/backend.tf`](stacks/ec2-fleet/backend.tf) |
| 2.2 Concurrent `apply` explanation | Answer | [Task 2](#task-2--remote-state--locking) |
| 3. Multi-account IAM | Design + answers | [Task 3](#task-3--multi-account-iam--cross-account-access) |
| 4. Least-privilege policy | Policy JSON + answer | [Task 4](#task-4--least-privilege-policy-for-ci) |

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

## Task 3 — Multi-Account IAM & Cross-Account Access

### Design

**Account A (`000000000000`)**

| Item | Configuration |
|---|---|
| `group1`: `engine`, `ci` | Programmatic access only: access keys, **no login profile**, so they cannot sign in to the console. `ci` gets the Task 4 policy. `engine` gets `sts:AssumeRole` on roleB. |
| `group2`: `alice`, `bob` | Console + CLI: login profile (password reset at first sign-in) plus access keys. The group policy lets members manage only their own password, MFA and keys, **denies everything else until MFA is used**, and allows assuming roleA with MFA. |
| `roleA` | Admin on everything except IAM. Trusted by alice and bob, **with MFA required**. |
| `roleB` | Its only permission is to assume roleC in Account B. Trusted by `engine` only. |

IAM groups **cannot be principals** in a trust policy. roleA and roleB therefore list the user ARNs, and the group policy grants the matching `sts:AssumeRole`.

**roleA permission policy:** everything except IAM.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AllServicesExceptIAM", "Effect": "Allow", "NotAction": "iam:*", "Resource": "*" },
    { "Sid": "ServiceLinkedRoles", "Effect": "Allow", "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::000000000000:role/aws-service-role/*" },
    { "Sid": "PassPreApprovedRolesOnly", "Effect": "Allow", "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::000000000000:role/workload/*" }
  ]
}
```

`Allow` + `NotAction: iam:*` grants every action outside the IAM namespace. Without the two narrow IAM exceptions, an "admin" could not launch an EC2 instance with an instance profile or an ECS task with a role.

PassRole is limited to `/workload/` roles that only IAM admins can create, because roleA cannot create or edit roles. That means PassRole cannot be used to escalate. Adding the same policy as a **permissions boundary** keeps the limit in place even if someone later attaches `AdministratorAccess`.

**roleB:** trust policy and permission policy.

```json
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": "sts:AssumeRole",
  "Principal": { "AWS": "arn:aws:iam::000000000000:user/engine" } }] }
```

```json
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::111111111111:role/roleC" }] }
```

**Account B (`111111111111`): roleC trust policy and permission policy.**

```json
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": "sts:AssumeRole",
  "Principal": { "AWS": "arn:aws:iam::000000000000:role/roleB" } }] }
```

```json
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": "s3:*",
  "Resource": [ "arn:aws:s3:::arrise-shared-data", "arn:aws:s3:::arrise-shared-data/*" ] }] }
```

Cross-account access needs **both sides** to agree: roleB's identity policy allows the call, and roleC's trust policy allows the caller. The resulting path is `engine → roleB → roleC → one bucket`.

### Q1. Would you give `engine` and `ci` IAM users with access keys in a real production setup?

**No.** Access keys are long-lived credentials that never expire on their own. They get copied into CI secret stores, environment variables, laptops and logs, and a leaked key works from anywhere until someone notices. Production machine identities should use **roles with short-lived, automatically rotated credentials**:

- **`ci` → OIDC federation.** Register the CI provider (e.g. `token.actions.githubusercontent.com`) as an IAM OIDC identity provider and create a CI role. The role's trust policy checks `aud = sts.amazonaws.com` and `sub = repo:<org>/<repo>:ref:refs/heads/main`. Each job receives roughly one-hour credentials, and **no secret is stored anywhere**. The Task 4 policy attaches to this role unchanged. This repo's CI `plan` job works this way. If CI runs on AWS (CodeBuild, or runners on EC2/EKS), use its service role or instance role.
- **`engine` → a workload role.** On AWS, use an EC2 instance profile, ECS task role, EKS Pod Identity/IRSA or Lambda execution role, where AWS issues and rotates the credentials. Off AWS, use **IAM Roles Anywhere**, which exchanges an X.509 certificate for temporary credentials. roleB's trust policy then names engine's role instead of a user.
- **People (group2) → IAM Identity Center** with the corporate IdP, MFA and permission sets, instead of IAM users.

If keys are truly unavoidable, use one key per user, automate rotation (≤ 90 days), store it in Secrets Manager, restrict where it works with `aws:SourceIp`/`aws:SourceVpce`, and alert on unusual use.

### Q2. In roleC's trust policy, why does it matter whether you trust the whole Account A root or roleB's specific ARN?

`arn:aws:iam::000000000000:root` does **not** mean the root user. It means **the whole of Account A**. It delegates the decision to Account A: **any** principal there whose own identity policy allows `sts:AssumeRole` on roleC can assume it. Account B loses control over who gets in.

In this exact design, **roleA would be able to assume roleC**. roleA allows everything except IAM, and that includes `sts:AssumeRole` on `*`. alice and bob could then bypass roleB entirely and get full access to Account B's bucket. The same applies to any future admin role or compromised CI identity in Account A.

Trusting `arn:aws:iam::000000000000:role/roleB` means:

- **Only roleB sessions qualify**, whatever permissions other principals in Account A have.
- **Account B keeps control** and can audit its exposure by reading one trust policy.
- **Re-creation is not trusted:** IAM stores roleB's unique ID. If someone deletes roleB and creates a new role with the same name, roleC does not trust it until the trust policy is saved again. That blocks impersonation.

If the account root must be trusted, add `"Condition": {"ArnEquals": {"aws:PrincipalArn": "arn:aws:iam::000000000000:role/roleB"}}`.

---

## Task 4 — Least-Privilege Policy for `ci`

Example targets: ECR repo `arrise/game-api`, ECS service `game-api` in cluster `arrise-dev`, artifact bucket `arrise-build-artifacts`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrLogin",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushToOneRepository",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:eu-west-1:000000000000:repository/arrise/game-api"
    },
    {
      "Sid": "RegisterTaskDefinitionForOneFamily",
      "Effect": "Allow",
      "Action": "ecs:RegisterTaskDefinition",
      "Resource": "arn:aws:ecs:eu-west-1:000000000000:task-definition/game-api:*"
    },
    {
      "Sid": "ReadCurrentTaskDefinition",
      "Effect": "Allow",
      "Action": "ecs:DescribeTaskDefinition",
      "Resource": "*"
    },
    {
      "Sid": "DeployToOneService",
      "Effect": "Allow",
      "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
      "Resource": "arn:aws:ecs:eu-west-1:000000000000:service/arrise-dev/game-api"
    },
    {
      "Sid": "PassOnlyThisServicesTaskRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::000000000000:role/game-api-task-execution",
        "arn:aws:iam::000000000000:role/game-api-task"
      ],
      "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } }
    },
    {
      "Sid": "ListArtifactBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::arrise-build-artifacts"
    },
    {
      "Sid": "ReadArtifacts",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::arrise-build-artifacts/*"
    }
  ]
}
```

**Why each part is needed**

- **`ecr:GetAuthorizationToken`** is needed for `docker login`. It does not support resource-level permissions, so `"*"` is required.
- **The six ECR actions** are exactly what `docker push` calls, scoped to one repository. Five upload the layers and the manifest. `BatchGetImage` is needed because, before writing the tag, Docker first sends a `HEAD` request for the manifest, which ECR authorizes as `BatchGetImage`. Without it the push fails with `403 Forbidden` after the layers have already uploaded. This was confirmed in a live test (see [Verification](#verification)).
- **A new ECS deployment** is `RegisterTaskDefinition` (scoped to the `game-api` family) → `UpdateService` → `DescribeServices`. `DescribeServices` is what `aws ecs wait services-stable` polls. `DescribeTaskDefinition` reads the current revision to build the next one. It is read-only and cannot be resource-scoped.
- **`iam:PassRole`** is required because the task definition references an execution role and a task role. It is limited to those two roles, and only when passed to ECS tasks.
- **`s3:ListBucket`** goes on the bucket ARN and **`s3:GetObject`** on the objects ARN. List is also what makes a missing object return 404 instead of 403.

### What was deliberately left out, and why

| Left out | Reason |
|---|---|
| `iam:PassRole` on `*` | **The critical omission.** CI could register a task definition that runs as an admin role and deploy it, turning a deploy credential into full account access. |
| ECR layer download (`GetDownloadUrlForLayer`) | Not needed to push. Together with `BatchGetImage` it would let CI pull images. Add it only if the build uses the repo as a layer cache. |
| ECR admin (`CreateRepository`, `DeleteRepository`, `BatchDeleteImage`, `SetRepositoryPolicy`, lifecycle/tag-mutability) | Repositories are owned by IaC. `BatchDeleteImage` could delete rollback images. |
| `ecs:CreateService`, `DeleteService`, `RunTask`, `StartTask`, `StopTask` | Deploying updates an **existing** service. `RunTask` would let CI run arbitrary tasks with the passed roles. |
| `ecs:DeregisterTaskDefinition` | Old revisions are rollback targets. |
| `ecs:ExecuteCommand` | A pipeline must never get a shell inside running containers. |
| `ecs:TagResource` | Only needed if task definitions are registered with tags. |
| `s3:PutObject`, `DeleteObject`, bucket configuration, `ListAllMyBuckets` | The requirement is read-only access to one known bucket. |
| `kms:Decrypt` | Only needed if the bucket uses SSE-KMS with a customer key. If so, scope it to that key with `kms:ViaService`. |
| CloudWatch Logs, wildcards like `ecs:*` | Not part of the job. Container logs are written by the task execution role, not CI. |

---

## Verification

These checks ran locally with Terraform 1.14.5 and AWS provider 6.72.0, without AWS credentials. CI runs the same checks, and `make ci` runs them locally.

| Check | Result |
|---|---|
| `terraform fmt -check`, `terraform validate` | clean / valid |
| TFLint (Terraform recommended + AWS ruleset) | 0 issues |
| Checkov | 0 failed. Every skip is inline next to its resource, with a reason. |
| `terraform test` (mocked provider) | 15 passing. The module has 10: protected/unprotected split, tags, IMDSv2/encryption/no public IP, volume settings, key pairs, outputs, and invalid input (including a fleet with no io1/io2 volume). The stack has 5: the committed 2-web/2-app/1-db tfvars meet every Task 1 rule, and each stack rule rejects a violating change. |

### Task 4 policy: tested in a real AWS account

The policy was checked in three ways against a real account, using throwaway resources: an ECR repo, an ECS cluster and service, an artifact bucket, and the two task roles.

| Check | Result |
|---|---|
| IAM Access Analyzer `validate-policy` | No errors, security warnings or suggestions |
| IAM policy simulator | 27/27 expected allow/deny decisions |
| Live run as an identity holding **only** this policy | **19/19**. Real `docker push`; describe → register → `update-service` → `wait services-stable`; S3 list and download all succeeded. Ten forbidden actions were denied: push to another repo, delete images or repo, register another family, pass an unapproved role, update another service, `CreateService`, `RunTask`, S3 write/delete. |

The live run found one gap the simulator could not. With only the five upload actions, `docker push` uploaded every layer and then failed with `403 Forbidden` on `HEAD /v2/<repo>/manifests/<tag>`. CloudTrail recorded it as `BatchGetImage AccessDenied`. `ecr:BatchGetImage` was added to the push statement, and the full run then passed.
