output "ecr_repository_url" {
  value = data.aws_ecr_repository.this.repository_url
}

output "ecr_repository_arn" {
  value = data.aws_ecr_repository.this.arn
}
