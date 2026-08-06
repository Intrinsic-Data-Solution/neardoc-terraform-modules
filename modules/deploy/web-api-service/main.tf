# ECR repo creation is owned by the CI pipeline (docker-build-push.yml's "ensure ECR
# repository exists" step runs BEFORE any docker push, which happens before this Deploy-stage
# terraform apply ever runs) — not by Terraform. This is a lookup, not a managed resource, so
# there's no create-time race or "already exists" conflict between the two.
data "aws_ecr_repository" "this" {
  name = var.ecr_repo_name
}

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

# Wake-then-deploy WITH an HTTP health-check wait after the SSM command succeeds — the
# distinguishing behavior vs the sibling background-service module, appropriate for services
# that actually expose an HTTP surface to verify against.
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
      HEALTH_ITERATIONS     = tostring(max(1, floor(var.health_check_timeout_seconds / var.health_check_poll_interval_seconds)))
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

      # IMAGE_TAG=$IMAGE_TAG is passed inline rather than relying on /opt/neardoc/.env's own
      # IMAGE_TAG - that file is only refreshed by user-data.sh at boot (defaults to "latest",
      # a tag this pipeline never actually pushes) and is shared across all 12 services, so
      # trusting it here would deploy whatever tag happened to be baked in at boot, not the tag
      # this exact apply just built. The inline override only affects this one command's
      # environment; other already-running services are untouched either way since "docker
      # compose up -d $COMPOSE_SERVICE_NAME" only touches the named service.
      #
      # The health check runs as a SECOND command in this SAME SSM invocation, on the box
      # itself, instead of an external curl from the CI agent against the box's public IP —
      # confirmed live that always times out regardless of app health, since neardoc-ec2-sg
      # deliberately only allows port 80 from CloudFront's prefix list, not arbitrary internet
      # clients. Also deliberately not routed through nginx's own /health even from on-box:
      # nginx has a depends_on on gateway-api, so nginx (and therefore ANY check that goes
      # through it) never comes up until gateway has ALSO been successfully deployed at least
      # once — a single service's health check must not be coupled to a completely different
      # service's deploy status. ".NET"'s aspnet-runtime base image also has no curl/wget to
      # self-check its own HTTP port from inside the container. Checking "is this service's
      # container running" via docker compose's own status view sidesteps all three.
      # Built with printf rather than a nested heredoc: this whole command block is ALREADY
      # inside Terraform's own <<-EOT heredoc, and a bash heredoc's closing marker must be
      # unindented (or tab-indented for <<-, which only strips tabs, not the spaces this file
      # uses) — nesting one inside the other risks the inner terminator ending up with residual
      # leading whitespace after Terraform's own stripping, which breaks heredoc parsing
      # silently. printf has no terminator-matching to get wrong. \$(seq...) and \$HEALTHY are
      # backslash-escaped so they stay literal text here and are only evaluated once, remotely,
      # when SSM actually runs this string as a shell command on the box.
      SSM_PARAMS_FILE=$(mktemp)
      printf '%s' "{\"commands\":[\"cd $COMPOSE_DIR && IMAGE_TAG=$IMAGE_TAG docker compose pull $COMPOSE_SERVICE_NAME && IMAGE_TAG=$IMAGE_TAG docker compose up -d $COMPOSE_SERVICE_NAME\",\"cd $COMPOSE_DIR; HEALTHY=0; for i in \$(seq 1 $HEALTH_ITERATIONS); do docker compose ps --status running --services 2>/dev/null | grep -qx '$COMPOSE_SERVICE_NAME' && HEALTHY=1 && break; sleep $HEALTH_POLL_INTERVAL; done; if [ \$HEALTHY -ne 1 ]; then echo container did not reach running state; docker compose logs --tail 30 $COMPOSE_SERVICE_NAME; exit 1; fi; echo container running\"]}" > "$SSM_PARAMS_FILE"

      # mktemp's POSIX-style /tmp/... path is meaningless to the native Windows aws.exe when
      # passed as a file:// URI (it's not auto-translated the way a bare path argument would
      # be) — confirmed live: "Unable to load paramfile file:///tmp/tmp.XXXXXX: No such file or
      # directory", despite the file existing fine at that path from Git Bash's own point of
      # view. cygpath -m converts it to the Windows-style forward-slash form aws.exe can
      # actually resolve.
      SSM_PARAMS_FILE_WIN=$(cygpath -m "$SSM_PARAMS_FILE")

      COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "deploy $COMPOSE_SERVICE_NAME:$IMAGE_TAG" \
        --parameters "file://$SSM_PARAMS_FILE_WIN" \
        --query "Command.CommandId" \
        --output text)

      rm -f "$SSM_PARAMS_FILE"

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
        echo "=== [web-api-service] SSM command did not succeed (final status: $STATUS) — this includes the on-box health check, which runs as part of the same command ==="
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$COMMAND_ID" \
          --instance-id "$INSTANCE_ID" \
          --query "StandardErrorContent" \
          --output text 2>/dev/null || true
        exit 1
      fi

      echo "=== [web-api-service] SSM command succeeded (deploy + on-box health check both passed) — touching $APP_STATE_LRA_ATTR so the idle-stop timer resets ==="

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

}
