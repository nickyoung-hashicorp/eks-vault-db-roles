read -p "Enable the database secrets engine[]"
vault secrets enable database

read -p "Save and echo the Postgres RDS address[]"
export RDS_ADDR=$(cat rds_address)
echo $RDS_ADDR

read -p "Configure the database secrets engine[]"
vault write database/config/product \
    plugin_name=postgresql-database-plugin \
    allowed_roles="*" \
    connection_url="postgresql://{{username}}:{{password}}@${RDS_ADDR}:5432/products?sslmode=disable" \
    username="postgres" \
    password="password"

read -p "Create rotation.sql statement[]"
cat > rotation.sql << EOF
ALTER USER "{{name}}" WITH PASSWORD '{{password}}';
EOF

read -p "Configure static database role with 20s rotation period[]"
vault write database/static-roles/product \
    db_name=product \
    rotation_statements=@rotation.sql \
    username="static-vault-user" \
    rotation_period=20

