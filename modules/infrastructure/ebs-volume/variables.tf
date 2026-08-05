variable "name" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "size_gb" {
  type    = number
  default = 50
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

variable "instance_id" {
  description = "Instance to attach this volume to."
  type        = string
}

variable "device_name" {
  type    = string
  default = "/dev/sdf"
}

# Note: prevent_destroy is intentionally NOT a variable — Terraform's `lifecycle` meta-argument
# values must be static literals, they cannot reference input variables. It's hardcoded `true`
# in main.tf; fork this module (or edit main.tf directly) if a consumer genuinely needs it off.

variable "tags" {
  type    = map(string)
  default = {}
}
