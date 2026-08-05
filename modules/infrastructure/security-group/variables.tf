variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "ingress_rules" {
  description = "List of ingress rules. `prefix_list_ids`/`cidr_blocks` are both optional per-rule; supply whichever the rule needs."
  type = list(object({
    description     = string
    from_port       = number
    to_port         = number
    protocol        = string
    cidr_blocks     = optional(list(string), [])
    prefix_list_ids = optional(list(string), [])
  }))
  default = []
}

variable "egress_rules" {
  type = list(object({
    description = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = optional(list(string), ["0.0.0.0/0"])
  }))
  default = [
    {
      description = "All outbound traffic"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

variable "tags" {
  type    = map(string)
  default = {}
}
