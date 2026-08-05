data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id

  user_data = templatefile("${path.module}/templates/user-data-base.sh.tpl", {
    mount_data_volume    = var.mount_data_volume
    data_mount_path      = var.data_mount_path
    config_s3_bucket     = var.config_s3_bucket
    config_s3_prefix     = var.config_s3_prefix
    app_root             = var.app_root
    aws_region           = var.aws_region
    additional_user_data = var.additional_user_data
  })
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-host-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "extra" {
  count  = var.extra_iam_policy_json != "" ? 1 : 0
  name   = "${var.name}-host-extra"
  role   = aws_iam_role.this.id
  policy = var.extra_iam_policy_json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-host-profile"
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = local.user_data
  # cloud-init reruns the (idempotent) user-data script on every boot regardless of content
  # changes at the OS level; this only controls whether *Terraform* replaces the instance when
  # the rendered script changes — false, since the instance should keep running and just pick
  # up new user-data on its next natural reboot/SSM-triggered rerun rather than being recreated.
  user_data_replace_on_change = false

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = var.root_volume_type
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_eip" "this" {
  count    = var.associate_eip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.this.id
  tags     = merge(var.tags, { Name = "${var.name}-eip" })
}
