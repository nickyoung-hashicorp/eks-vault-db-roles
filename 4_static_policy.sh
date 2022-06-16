cat > product-static.hcl << EOF
path "database/static-creds/product-static" {
  capabilities = ["read"]
}
EOF
vault policy write product-static ./product-static.hcl
vault write auth/kubernetes/role/product-static \
    bound_service_account_names=product \
    bound_service_account_namespaces=default \
    policies=product-static \
    ttl=1h