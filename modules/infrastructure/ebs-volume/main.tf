# Standalone EBS volume, declared independently of any instance's root/ebs_block_device so its
# lifecycle is fully decoupled — an instance can be destroyed and recreated without touching
# this volume or its data; re-attach via a new aws_volume_attachment against the new instance_id.
resource "aws_ebs_volume" "this" {
  availability_zone = var.availability_zone
  size              = var.size_gb
  type              = var.volume_type
  tags              = merge(var.tags, { Name = var.name })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "this" {
  device_name = var.device_name
  volume_id   = aws_ebs_volume.this.id
  instance_id = var.instance_id
}
