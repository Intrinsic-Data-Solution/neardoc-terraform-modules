output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "public_ip" {
  description = "Elastic IP if var.associate_eip is true, otherwise the instance's default public IP (if any)."
  value       = var.associate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip
}

output "availability_zone" {
  value = aws_instance.this.availability_zone
}

output "iam_role_arn" {
  value = aws_iam_role.this.arn
}

output "iam_role_name" {
  value = aws_iam_role.this.name
}

output "iam_instance_profile_name" {
  value = aws_iam_instance_profile.this.name
}
