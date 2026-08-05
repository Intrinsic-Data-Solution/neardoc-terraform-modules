variable "service_name" {
  description = "Service identifier, used for resource naming/tagging."
  type        = string
}

variable "ecr_repo_name" {
  description = "Full ECR repository name, e.g. \"neardoc/payment-worker\"."
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
  description = "Name of the platform's wake/start Lambda function. Invoked synchronously to wake the host before deploying, only when the app-state item's status is not RUNNING."
  type        = string
  default     = "neardoc-start"
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
