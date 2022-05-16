# Outputs file
output "vault_ssh" {
  value = "ssh -i ssh-key.pem ubuntu@${aws_eip.vault.public_ip}"
}

output "vault_ip" {
  value = aws_eip.vault.public_ip
}

# Output RDS endpoint with port
# output "rds-endpoint" { value = aws_db_instance.rds.endpoint }