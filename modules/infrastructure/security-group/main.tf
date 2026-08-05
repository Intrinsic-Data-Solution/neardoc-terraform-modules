resource "aws_security_group" "this" {
  # name_prefix (not a fixed name) + create_before_destroy: on any change that forces
  # replacement, Terraform must be able to create the new SG (and re-point dependents at it)
  # BEFORE destroying the old one — a fixed `name` would collide with the still-existing old
  # SG during that window, and without create_before_destroy the default destroy-then-create
  # order tries to delete a SG that's still attached to a running instance, which AWS refuses
  # (DependencyViolation) — this is exactly the failure this module originally hit live.
  name_prefix = "${var.name}-"
  description = "Managed by neardoc-terraform-modules//modules/infrastructure/security-group"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      description     = ingress.value.description
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      cidr_blocks     = length(ingress.value.cidr_blocks) > 0 ? ingress.value.cidr_blocks : null
      prefix_list_ids = length(ingress.value.prefix_list_ids) > 0 ? ingress.value.prefix_list_ids : null
    }
  }

  dynamic "egress" {
    for_each = var.egress_rules
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  tags = merge(var.tags, { Name = var.name })
}
