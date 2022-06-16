cat > product.hcl << EOF
path "database/static-creds/product" {
  capabilities = ["read"]
}
EOF
vault policy write product ./product.hcl
vault write auth/kubernetes/role/product \
    bound_service_account_names=product \
    bound_service_account_namespaces=default \
    policies=product \
    ttl=1h