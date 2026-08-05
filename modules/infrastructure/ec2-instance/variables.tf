variable "name" {
  description = "Name prefix for every resource this module creates (instance, IAM role, instance profile, EIP)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "Explicit AMI ID to use. Leave empty (default) to auto-select the latest Ubuntu 22.04 LTS AMI from Canonical (owner 099720109477)."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet to launch the instance into."
  type        = string
}

variable "security_group_ids" {
  description = "Security group IDs to attach (e.g. from the sibling security-group module)."
  type        = list(string)
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 30
}

variable "root_volume_type" {
  type    = string
  default = "gp3"
}

variable "associate_eip" {
  description = "Whether to allocate and associate an Elastic IP (gives the instance a stable public IP across stop/start cycles)."
  type        = bool
  default     = true
}

# --- IAM ---

variable "managed_policy_arns" {
  description = "AWS managed policy ARNs to attach to the instance role. AmazonSSMManagedInstanceCore is included by default so SSM Run Command / Session Manager work without needing SSH."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
}

variable "extra_iam_policy_json" {
  description = "Optional additional IAM policy document (JSON string, e.g. from data.aws_iam_policy_document.json) merged into the instance role as an extra inline policy. Empty string (default) adds nothing beyond managed_policy_arns."
  type        = string
  default     = ""
}

# --- User data composition ---

variable "aws_region" {
  description = "Region, used inside the base user-data script for the ECR login step."
  type        = string
}

variable "mount_data_volume" {
  description = "Whether the base user-data script should detect, format (if needed), and mount an attached (but unformatted) data EBS device."
  type        = bool
  default     = false
}

variable "data_mount_path" {
  type    = string
  default = "/opt/data"
}

variable "config_s3_bucket" {
  description = "If set, the base user-data script logs into ECR and syncs s3://<bucket>/<config_s3_prefix> to app_root on every boot. Leave empty to skip this step entirely."
  type        = string
  default     = ""
}

variable "config_s3_prefix" {
  type    = string
  default = ""
}

variable "app_root" {
  description = "Local path the S3 config sync (if enabled) writes to."
  type        = string
  default     = "/opt/app"
}

variable "additional_user_data" {
  description = "Caller-specific shell script content, appended verbatim after the generic base provisioning (Docker/AWS-CLI install, optional data-volume mount, optional config sync). This is where application-specific bootstrapping (secret pulls, docker compose up, etc.) belongs — this module has no knowledge of any particular application."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
