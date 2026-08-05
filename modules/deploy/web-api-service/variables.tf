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

variable "health_check_target_host" {
  description = "Host/IP to poll for the post-deploy health check, e.g. the box's Elastic IP. Polls straight over HTTP on the box's public interface — matches the platform's plain-HTTP-origin decision, not through the public CDN hostname (avoids the check depending on CloudFront/DNS being in a healthy state as a precondition of a service deploy succeeding)."
  type        = string
}

variable "health_check_path" {
  description = "Path polled for a 200 response after the SSM deploy command succeeds. Default is nginx's own aggregate /health — override to a service-specific path (e.g. /bff/health behind the gateway route) if a deeper check is wanted."
  type        = string
  default     = "/health"
}

variable "health_check_port" {
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
