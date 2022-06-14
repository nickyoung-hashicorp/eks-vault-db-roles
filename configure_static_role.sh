read -p "Enable the database secrets engine[]"
vault secrets enable database

read -p "Save and echo the Postgres pod's hostname[]"
export POSTGRES_IP=$(kubectl get service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
   postgres)
echo $POSTGRES_IP

read -p "Configure the database secrets engine[]"
vault write database/config/product-static \
    plugin_name=postgresql-database-plugin \
    allowed_roles="*" \
    connection_url="postgresql://{{username}}:{{password}}@${POSTGRES_IP}:5432/products?sslmode=disable" \
    username="postgres" \
    password="password"

read -p "Create rotation.sql statement[]"
cat > rotation.sql << EOF
ALTER USER "{{name}}" WITH PASSWORD '{{password}}';
EOF

read -p "Configure static database role with 20s rotation period[]"
vault write database/static-roles/product-static \
    db_name=product-static \
    rotation_statements=@rotation.sql \
    username="static-vault-user" \
    rotation_period=20

