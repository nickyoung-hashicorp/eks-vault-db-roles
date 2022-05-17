# SSH to Vault instance
output "vault_ssh" {
  value = "ssh -i ssh-key.pem ubuntu@${aws_eip.vault.public_ip}"
}

# Vault IP
output "vault_ip" {
  value = aws_eip.vault.public_ip
}

# Output RDS address
output "rds-address" {
  value = aws_db_instance.rds.address
}