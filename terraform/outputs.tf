output "instance_public_ip" {
  description = "Public IPv4 address of the EC2 instance created by this configuration."
  value       = aws_instance.ops-3-instance.public_ip
}

output "instance_id" {
  description = "The ID of the EC2 instance (useful for further scripting or referencing)."
  value       = aws_instance.ops-3-instance.id
}

output "repository_url" {
  value = aws_ecr_repository.minecraft.repository_url
}
