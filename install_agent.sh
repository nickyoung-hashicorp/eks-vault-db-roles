helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
cat > values.yaml << EOF
injector:
   enabled: true
   externalVaultAddr: "${VAULT_ADDR}"
EOF

# Check that Vault's public IP rendered properly
more values.yaml

# Install Vault Agent
helm install vault -f values.yaml hashicorp/vault --version "0.19.0"

# Check `vault-agent-injector-*` pod for `RUNNING` status
kubectl wait po --for=condition=Ready -l app.kubernetes.io/instance=vault