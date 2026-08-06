# ECR repo creation is owned by the CI pipeline (docker-build-push.yml's "ensure ECR
# repository exists" step runs BEFORE any docker push, which happens before this Deploy-stage
# terraform apply ever runs) — not by Terraform. This is a lookup, not a managed resource, so
# there's no create-time race or "already exists" conflict between the two.
data "aws_ecr_repository" "this" {
  name = var.ecr_repo_name
}

# Standard two-rule policy: expire untagged images past a short retention window, then cap total
# image count regardless of tag status.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = data.aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than ${var.ecr_untagged_expire_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.ecr_image_keep_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_image_keep_count
        }
        action = { type = "expire" }
      }
    ]
  })
}

# Wake-then-deploy, no HTTP health check (background/worker services have no HTTP surface to
# poll — success is defined as "the SSM command that restarted the container completed"). See
# the sibling web-api-service module for the HTTP-health-check variant.
resource "terraform_data" "deploy_trigger" {
  triggers_replace = [var.image_tag]

  provisioner "local-exec" {
    # Local-Agents is Windows-only today; Git Bash exists at this fixed path (see
    # neardoc-infra CONVENTIONS.md's "Windows agent + bash" note for the same reasoning applied
    # to the Azure Pipelines YAML templates).
    interpreter = ["C:/Program Files/Git/bin/bash.exe", "-c"]

    environment = {
      AWS_REGION            = var.aws_region
      INSTANCE_ID           = var.instance_id
      COMPOSE_SERVICE_NAME  = var.compose_service_name
      COMPOSE_DIR           = var.compose_dir
      IMAGE_TAG             = var.image_tag
      START_LAMBDA_NAME     = var.start_lambda_function_name
      START_LAMBDA_TIMEOUT  = tostring(var.start_lambda_wait_seconds)
      APP_STATE_TABLE       = var.app_state_table_name
      APP_STATE_PK          = var.app_state_partition_key
      APP_STATE_PK_VALUE    = var.app_state_partition_value
      APP_STATE_STATUS_ATTR = var.app_state_status_attr
      APP_STATE_LRA_ATTR    = var.app_state_last_request_attr
      SSM_TIMEOUT_SECONDS   = tostring(var.ssm_command_timeout_seconds)
      SSM_POLL_INTERVAL     = tostring(var.ssm_poll_interval_seconds)
    }

    command = <<-EOT
      set -euo pipefail

      echo "=== [background-service] ${var.service_name}: checking app-state ($APP_STATE_TABLE) before deploying image tag $IMAGE_TAG ==="

      CURRENT_STATUS=$(aws dynamodb get-item \
        --region "$AWS_REGION" \
        --table-name "$APP_STATE_TABLE" \
        --key "{\"$APP_STATE_PK\": {\"S\": \"$APP_STATE_PK_VALUE\"}}" \
        --query "Item.$APP_STATE_STATUS_ATTR.S" \
        --output text 2>/dev/null || echo "NONE")

      if [ "$CURRENT_STATUS" != "RUNNING" ]; then
        echo "=== [background-service] box not RUNNING (status=$CURRENT_STATUS) — invoking $START_LAMBDA_NAME synchronously ==="
        RESP_FILE=$(mktemp)
        aws lambda invoke \
          --region "$AWS_REGION" \
          --function-name "$START_LAMBDA_NAME" \
          --invocation-type RequestResponse \
          --cli-read-timeout "$START_LAMBDA_TIMEOUT" \
          "$RESP_FILE"
        cat "$RESP_FILE"
        rm -f "$RESP_FILE"
        echo "=== [background-service] start lambda returned — proceeding to deploy ==="
      else
        echo "=== [background-service] box already RUNNING — skipping wake ==="
      fi

      echo "=== [background-service] sending SSM deploy command for compose service '$COMPOSE_SERVICE_NAME' on instance $INSTANCE_ID ==="

      # IMAGE_TAG=$IMAGE_TAG is passed inline rather than relying on /opt/neardoc/.env's own
      # IMAGE_TAG - see the identical note in the sibling web-api-service module for the full
      # reasoning (that file's IMAGE_TAG defaults to "latest", a tag this pipeline never
      # actually pushes, and is shared across all 12 services).
      COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "deploy $COMPOSE_SERVICE_NAME:$IMAGE_TAG" \
        --parameters commands="cd $COMPOSE_DIR && IMAGE_TAG=$IMAGE_TAG docker compose pull $COMPOSE_SERVICE_NAME && IMAGE_TAG=$IMAGE_TAG docker compose up -d $COMPOSE_SERVICE_NAME" \
        --query "Command.CommandId" \
        --output text)

      echo "=== [background-service] SSM CommandId: $COMMAND_ID — polling for completion ==="

      ELAPSED=0
      STATUS="Pending"

      while [ "$ELAPSED" -lt "$SSM_TIMEOUT_SECONDS" ]; do
        sleep "$SSM_POLL_INTERVAL"
        ELAPSED=$((ELAPSED + SSM_POLL_INTERVAL))

        STATUS=$(aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$COMMAND_ID" \
          --instance-id "$INSTANCE_ID" \
          --query "Status" \
          --output text 2>/dev/null || echo "Pending")

        echo "=== [background-service] SSM status: $STATUS (elapsed $${ELAPSED}s) ==="

        case "$STATUS" in
          Success|Failed|Cancelled|TimedOut)
            break
            ;;
        esac
      done

      if [ "$STATUS" != "Success" ]; then
        echo "=== [background-service] SSM command did not succeed (final status: $STATUS) ==="
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$COMMAND_ID" \
          --instance-id "$INSTANCE_ID" \
          --query "StandardErrorContent" \
          --output text 2>/dev/null || true
        exit 1
      fi

      echo "=== [background-service] deploy succeeded — touching $APP_STATE_LRA_ATTR so the idle-stop timer resets ==="

      NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

      aws dynamodb update-item \
        --region "$AWS_REGION" \
        --table-name "$APP_STATE_TABLE" \
        --key "{\"$APP_STATE_PK\": {\"S\": \"$APP_STATE_PK_VALUE\"}}" \
        --update-expression "SET $APP_STATE_LRA_ATTR = :now" \
        --expression-attribute-values "{\":now\": {\"S\": \"$NOW_ISO\"}}"

      echo "=== [background-service] ${var.service_name} done ==="
    EOT
  }

}
