# Local quality gates. CI (.github/workflows/terraform.yml) runs the same steps.
#
#   make help       list targets
#   make ci         everything below, in CI order
#
# None of these targets need AWS credentials: init skips the backend, tests
# use mocked or offline providers, and nothing is planned against AWS.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

ROOT_DIRS   := bootstrap/state-backend stacks/ec2-fleet
MODULE_DIRS := modules/ec2-fleet
TF_DIRS     := $(ROOT_DIRS) $(MODULE_DIRS)
TEST_DIRS   := $(foreach d,$(TF_DIRS),$(if $(wildcard $(d)/tests/*.tftest.hcl),$(d)))

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: fmt
fmt: ## Format all Terraform files
	terraform fmt -recursive

.PHONY: fmt-check
fmt-check: ## Fail if any file is not formatted
	terraform fmt -recursive -check -diff

.PHONY: init
init: ## terraform init (no backend) in every directory
	@for d in $(TF_DIRS); do echo "==> init $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null; done

.PHONY: validate
validate: init ## terraform validate in every directory
	@for d in $(TF_DIRS); do echo "==> validate $$d"; terraform -chdir=$$d validate; done

.PHONY: lint
lint: ## TFLint (Terraform + AWS rulesets)
	tflint --init --config="$(CURDIR)/.tflint.hcl"
	@for d in $(TF_DIRS); do echo "==> tflint $$d"; tflint --chdir=$$d --config="$(CURDIR)/.tflint.hcl"; done

.PHONY: security
security: ## Checkov static security scan
	checkov -d . --config-file .checkov.yaml

.PHONY: test
test: init ## terraform test (offline unit tests)
	@for d in $(TEST_DIRS); do echo "==> test $$d"; terraform -chdir=$$d test; done

.PHONY: docs
docs: ## Regenerate input/output tables in module and stack READMEs
	@for d in $(TF_DIRS); do terraform-docs --config .terraform-docs.yml $$d; done

.PHONY: ci
ci: fmt-check validate lint security test ## Run every check, as CI does

.PHONY: clean
clean: ## Remove local .terraform directories
	find . -type d -name .terraform -prune -exec rm -rf {} +
