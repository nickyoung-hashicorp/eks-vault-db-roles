read -p "Enable the database secrets engine[]"
vault secrets enable database

read -p "Save and echo the Postgres pod's hostname[]"
export RDS_ADDR=$(terraform output rds-address)
echo $RDS_ADDR

read -p "Configure the database secrets engine[]"
vault write database/config/product \
    plugin_name=postgresql-database-plugin \
    allowed_roles="*" \
    connection_url="postgresql://{{username}}:{{password}}@${RDS_ADDR}:5432/products?sslmode=disable" \
    username="postgres" \
    password="password"

read -p "Creaet a role called 'product' with a 20s TTL[]"
vault write database/roles/product \
    db_name=product \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="ALTER ROLE \"{{name}}\" NOLOGIN;"\
    default_ttl="20s" \
    max_ttl="20s"
