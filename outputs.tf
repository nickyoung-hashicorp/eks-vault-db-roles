# Vault IP
output "vault_ip" {
  value = aws_eip.vault.public_ip
}

# Output RDS address
output "rds_address" {
  value = aws_db_instance.rds.address
}