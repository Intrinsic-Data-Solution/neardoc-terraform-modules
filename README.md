# neardoc-terraform-modules

Reusable Terraform modules referenced by `neardoc-infra` (for provisioning shared platform
infrastructure) and by every microservice repo's own `terraform/` folder (for deploying that
one service in isolation).

## Layout

```
modules/
├── infrastructure/         # generic compute-platform building blocks
│   ├── security-group/     # reusable ingress/egress security group
│   ├── ebs-volume/         # standalone EBS volume + attachment, lifecycle-decoupled from the instance
│   └── ec2-instance/       # EC2 host: instance + EIP + IAM role/instance-profile + composable user-data
│       # (a sibling `ecs-cluster/` module is the intended next addition once ECS is in scope —
│       #  not built yet, this module family is structured so it slots in the same way)
└── deploy/                 # per-microservice deploy modules — ECR repo + wake-then-SSM-deploy trigger
    ├── web-api-service/     # for services that expose an HTTP API — waits for /health after deploy
    └── background-service/  # for workers with no HTTP surface — no health-check wait
```

## `modules/infrastructure/ec2-instance`

Generic EC2 host module. User-data is composed in two layers:

1. **Base** (`templates/user-data-base.sh.tpl`, always included): installs Docker + AWS CLI,
   optionally formats/mounts a data EBS device (`mount_data_volume`), optionally logs into ECR
   and syncs a config prefix from S3 (`config_s3_bucket`/`config_s3_prefix`).
2. **Additional** (`var.additional_user_data`, caller-supplied, appended verbatim after the base
   script): anything specific to the consuming platform — e.g. neardoc-infra's own
   SSM-Parameter-Store secret pull + `docker compose up -d`. This is what keeps the module
   generic — it knows nothing about Neardoc's compose file, SSM param naming, or database
   connection strings; all of that lives in the *caller's* `additional_user_data` string.

See `modules/infrastructure/ec2-instance/variables.tf` for the full input list.

## `modules/deploy/{web-api-service,background-service}`

Both create: an ECR repository + lifecycle policy, and a `terraform_data` trigger that (a) wakes
the target EC2 host via the platform's `neardoc-start` Lambda if it's stopped, (b) runs
`docker compose pull <compose_service_name> && docker compose up -d <compose_service_name>` on
the host via SSM Run Command, (c) touches the app-state DynamoDB item's `lastRequestAt` so the
idle-stop timer resets. `web-api-service` additionally polls `http://<target_host>/health`
(configurable path) after the SSM command succeeds, before declaring the deploy done —
`background-service` has no HTTP surface to poll, so it stops after the SSM command succeeds.

Both modules take the DynamoDB app-state table's key schema as variables (defaults match what
`neardoc-infra`'s `platform/modules/dynamodb-state` actually creates: hash key `id`, singleton
item `id="host"`, `status`/`lastRequestAt` attributes) — override if a different platform's state
table uses different names.

## Versioning

Consumers pin a `ref` when sourcing these modules, e.g.:

```hcl
module "ec2" {
  source = "git::https://github.com/Intrinsic-Data-Solution/neardoc-terraform-modules.git//modules/infrastructure/ec2-instance?ref=main"
  ...
}
```

Using `ref=main` tracks the latest commit — pin to a tag once this repo has a release process:
until then, an update here immediately affects every consumer on the next `terraform init -upgrade`.
