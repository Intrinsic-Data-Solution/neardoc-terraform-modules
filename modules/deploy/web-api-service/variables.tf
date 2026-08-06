variable "service_name" {
  description = "Service identifier, used for resource naming/tagging."
  type        = string
}

variable "ecr_repo_name" {
  description = "Full ECR repository name, e.g. \"neardoc/gateway\"."
  type        = string
}

variable "compose_service_name" {
  description = "The docker-compose service key to pull/restart on the target host."
  type        = string
}

variable "image_tag" {
  description = "Image tag to deploy, e.g. a git SHA. Changing this re-triggers the deploy provisioner."
  type        = string
}

variable "instance_id" {
  description = "EC2 instance ID to target with SSM commands."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "af-south-1"
}

variable "compose_dir" {
  description = "Directory on the target host containing docker-compose.yml (the SSM command cd's here before running docker compose)."
  type        = string
  default     = "/opt/app"
}

variable "start_lambda_function_name" {
  type    = string
  default = "neardoc-start"
}

# --- Health check (the difference from the background-service module) ---

# health_check_target_host/path/port are no longer used internally as of the switch to an
# on-box container-status check (main.tf's SSM commands array) instead of an external HTTP
# curl — that external check always timed out in practice, since neardoc-ec2-sg deliberately
# only allows port 80 from CloudFront's prefix list, not arbitrary internet clients (this
# module's own CI agent included), and even from on-box, nginx's /health is coupled to
# gateway-api also being deployed via nginx's depends_on — a single service's health must not
# depend on a different service's deploy status. Left declared (unused) rather than removed, so
# every existing caller's terraform/main.tf that still passes health_check_target_host doesn't
# need editing across all 9 web-api-service repos for a no-op variable.
variable "health_check_target_host" {
  description = "Unused as of the on-box container-status health check switch - see the comment above. Kept only so existing callers don't need to drop this argument."
  type        = string
  default     = null
}

variable "health_check_path" {
  description = "Unused as of the on-box container-status health check switch - see the comment above."
  type        = string
  default     = "/health"
}

variable "health_check_port" {
  description = "Unused as of the on-box container-status health check switch - see the comment above."
  type    = number
  default = 80
}

variable "health_check_timeout_seconds" {
  type    = number
  default = 60
}

variable "health_check_poll_interval_seconds" {
  type    = number
  default = 5
}

# --- App-state DynamoDB table shape (defaults match neardoc-infra's platform/modules/dynamodb-state) ---

variable "app_state_table_name" {
  type    = string
  default = "neardoc-app-state"
}

variable "app_state_partition_key" {
  type    = string
  default = "id"
}

variable "app_state_partition_value" {
  type    = string
  default = "host"
}

variable "app_state_status_attr" {
  type    = string
  default = "status"
}

variable "app_state_last_request_attr" {
  type    = string
  default = "lastRequestAt"
}

variable "ssm_command_timeout_seconds" {
  type    = number
  default = 300
}

variable "ssm_poll_interval_seconds" {
  type    = number
  default = 5
}

variable "start_lambda_wait_seconds" {
  type    = number
  default = 300
}

variable "ecr_image_keep_count" {
  type    = number
  default = 10
}

variable "ecr_untagged_expire_days" {
  type    = number
  default = 14
}
