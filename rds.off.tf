# Provision PostgreSQL RDS Database
resource "aws_db_instance" "rds" {
  availability_zone      = "us-west-2a"
  vpc_security_group_ids = [aws_security_group.postgres.id]
  port                   = "5432"
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  db_name                = "postgresdb"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "14.1"
  instance_class         = "db.t3.micro"
  username               = "postgres"
  password               = "password"
  parameter_group_name   = "default.postgres14"
  skip_final_snapshot    = true
}

