resource "aws_ecr_repository" "this" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

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

# Wake-then-deploy WITH an HTTP health-check wait after the SSM command succeeds — the
# distinguishing behavior vs the sibling background-service module, appropriate for services
# that actually expose an HTTP surface to verify against.
resource "terraform_data" "deploy_trigger" {
  triggers_replace = [var.image_tag]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

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
      HEALTH_URL            = "http://${var.health_check_target_host}:${var.health_check_port}${var.health_check_path}"
      HEALTH_TIMEOUT        = tostring(var.health_check_timeout_seconds)
      HEALTH_POLL_INTERVAL  = tostring(var.health_check_poll_interval_seconds)
    }

    command = <<-EOT
      set -euo pipefail

      echo "=== [web-api-service] ${var.service_name}: checking app-state ($APP_STATE_TABLE) before deploying image tag $IMAGE_TAG ==="

      CURRENT_STATUS=$(aws dynamodb get-item \
        --region "$AWS_REGION" \
        --table-name "$APP_STATE_TABLE" \
        --key "{\"$APP_STATE_PK\": {\"S\": \"$APP_STATE_PK_VALUE\"}}" \
        --query "Item.$APP_STATE_STATUS_ATTR.S" \
        --output text 2>/dev/null || echo "NONE")

      if [ "$CURRENT_STATUS" != "RUNNING" ]; then
        echo "=== [web-api-service] box not RUNNING (status=$CURRENT_STATUS) — invoking $START_LAMBDA_NAME synchronously ==="
        RESP_FILE=$(mktemp)
        aws lambda invoke \
          --region "$AWS_REGION" \
          --function-name "$START_LAMBDA_NAME" \
          --invocation-type RequestResponse \
          --cli-read-timeout "$START_LAMBDA_TIMEOUT" \
          "$RESP_FILE"
        cat "$RESP_FILE"
        rm -f "$RESP_FILE"
        echo "=== [web-api-service] start lambda returned — proceeding to deploy ==="
      else
        echo "=== [web-api-service] box already RUNNING — skipping wake ==="
      fi

      echo "=== [web-api-service] sending SSM deploy command for compose service '$COMPOSE_SERVICE_NAME' on instance $INSTANCE_ID ==="

      COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "deploy $COMPOSE_SERVICE_NAME:$IMAGE_TAG" \
        --parameters commands="cd $COMPOSE_DIR && docker compose pull $COMPOSE_SERVICE_NAME && docker compose up -d $COMPOSE_SERVICE_NAME" \
        --query "Command.CommandId" \
        --output text)

      echo "=== [web-api-service] SSM CommandId: $COMMAND_ID — polling for completion ==="

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

        echo "=== [web-api-service] SSM status: $STATUS (elapsed $${ELAPSED}s) ==="

        case "$STATUS" in
          Success|Failed|Cancelled|TimedOut)
            break
            ;;
        esac
      done

      if [ "$STATUS" != "Success" ]; then
        echo "=== [web-api-service] SSM command did not succeed (final status: $STATUS) ==="
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$COMMAND_ID" \
          --instance-id "$INSTANCE_ID" \
          --query "StandardErrorContent" \
          --output text 2>/dev/null || true
        exit 1
      fi

      echo "=== [web-api-service] SSM command succeeded — polling $HEALTH_URL ==="

      HEALTH_ELAPSED=0
      HEALTHY=0
      while [ "$HEALTH_ELAPSED" -lt "$HEALTH_TIMEOUT" ]; do
        if curl -fsS -o /dev/null -m 5 "$HEALTH_URL"; then
          HEALTHY=1
          break
        fi
        sleep "$HEALTH_POLL_INTERVAL"
        HEALTH_ELAPSED=$((HEALTH_ELAPSED + HEALTH_POLL_INTERVAL))
        echo "=== [web-api-service] health check not yet passing (elapsed $${HEALTH_ELAPSED}s) ==="
      done

      if [ "$HEALTHY" -ne 1 ]; then
        echo "=== [web-api-service] health check did not pass within $${HEALTH_TIMEOUT}s — failing deploy ==="
        exit 1
      fi

      echo "=== [web-api-service] health check passed — touching $APP_STATE_LRA_ATTR so the idle-stop timer resets ==="

      NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

      aws dynamodb update-item \
        --region "$AWS_REGION" \
        --table-name "$APP_STATE_TABLE" \
        --key "{\"$APP_STATE_PK\": {\"S\": \"$APP_STATE_PK_VALUE\"}}" \
        --update-expression "SET $APP_STATE_LRA_ATTR = :now" \
        --expression-attribute-values "{\":now\": {\"S\": \"$NOW_ISO\"}}"

      echo "=== [web-api-service] ${var.service_name} done ==="
    EOT
  }

  depends_on = [aws_ecr_repository.this]
}
