# Guide to Demonstrate Vault's Dynamic and Static Database Roles on EKS

## Deploy Vault, EKS, and AWS resources
Clone repository and provision.
```sh
git clone https://github.com/nickyoung-hashicorp/eks-vault-db-roles.git
cd eks-vault-db-roles
terraform init && nohup terraform apply -auto-approve -parallelism=20 > apply.log &
```
The EKS cluster can take 15-20 minutes to provision, so you can run `tail -f apply.log` to check on the apply.

Once the `null-resource.configure-vault` process appears finished, open a new terminal tab and configure Vault on the EC2 instance.

### Configure Vault
Open a new terminal session and SSH to the EC2 instance:
```sh
cd eks-vault-db-roles
ssh -i ssh-key.pem ubuntu@$(terraform output vault_ip)
```

Install Vault:
```sh
sudo su
apt update -y && apt install jq -y
./install_vault.sh
export VAULT_ADDR=http://127.0.0.1:8200
vault operator init -format=json -key-shares=1 -key-threshold=1 > /home/ubuntu/init.json
vault operator unseal $(cat /home/ubuntu/init.json | jq -r '.unseal_keys_b64[0]')
cat init.json | jq -r '.root_token' # Copy and save this root token for later.
exit # from root
exit # the EC2 instance
```

## Setup Workstation

Install Vault:
```sh
export VAULT_VERSION=1.10.3 # Choose your desired Vault version
wget https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
unzip -j vault_*_linux_amd64.zip -d /usr/local/bin
export VAULT_TOKEN=<root_token>
export VAULT_ADDR=http://$(terraform output vault_ip):8200
```

Setup local environment
```sh
# Define AWS region
export AWS_DEFAULT_REGION=us-west-2

# Install awscli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 > get_helm.sh
chmod 700 get_helm.sh
./get_helm.sh

# Remove files
rm -rf aws awscliv2.zip get_helm.sh vault_*_linux_amd64.zip
```
Return to your first terminal session and see if the apply is complete and your EKS cluster is provisioned before proceeding.

Configure `kubectl`
```sh
export EKS_CLUSTER=k8squickstart-cluster
aws eks --region ${AWS_DEFAULT_REGION} update-kubeconfig --name ${EKS_CLUSTER}
```

Test EKS cluster
```sh
kubectl get po -A
```
If you see pods running in the `kube-system` namespace, you are ready to go.

### Install Vault Agent on EKS
```sh
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
cat > values.yaml << EOF
injector:
   enabled: true
   externalVaultAddr: "${VAULT_ADDR}"
EOF
more values.yaml
helm install vault -f values.yaml hashicorp/vault --version "0.19.0"
```

### Check `vault-agent-injector-*` pod for `RUNNING` status
```sh
kubectl get po
```

## Configure Dynamic Database Credentials

### Configure Kubernetes Auth Method on Vault
```sh
vault auth enable kubernetes
export TOKEN_REVIEW_JWT=$(kubectl get secret \
   $(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') \
   -o jsonpath='{ .data.token }' | base64 --decode)
export KUBE_CA_CERT=$(kubectl get secret \
   $(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') \
   -o jsonpath='{ .data.ca\.crt }' | base64 --decode)
export KUBE_HOST=$(kubectl config view --raw --minify --flatten \
   -o jsonpath='{.clusters[].cluster.server}')
vault write auth/kubernetes/config \
   token_reviewer_jwt="$TOKEN_REVIEW_JWT" \
   kubernetes_host="$KUBE_HOST" \
   kubernetes_ca_cert="$KUBE_CA_CERT"
```

### Deploy example workload with Postgres database
```sh
git clone https://github.com/hashicorp/vault-guides.git
cd vault-guides/cloud/eks-hcp-vault/
```

### Deploy `postgres-*` database pod and check for `RUNNING` status
```sh
kubectl apply -f postgres.yaml
kubectl get po
```

### Add database role to Vault
```sh
vault secrets enable database
export POSTGRES_IP=$(kubectl get service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
   postgres)
vault write database/config/products \
    plugin_name=postgresql-database-plugin \
    allowed_roles="*" \
    connection_url="postgresql://{{username}}:{{password}}@${POSTGRES_IP}:5432/products?sslmode=disable" \
    username="postgres" \
    password="password"
vault write database/roles/product \
    db_name=products \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="ALTER ROLE \"{{name}}\" NOLOGIN;"\
    default_ttl="30s" \
    max_ttl="60s"
```
If this fails with an error that looks like `* error creating database object: error verifying connection: dial tcp: lookup a986ca57f20914c29b53f61ff0b7d960-2128898780.us-west-2.elb.amazonaws.com on 127.0.0.53:53: no such host`, check the EKS security group and open all inbound traffic from anywhere.

### Test generating dynamic credentials
```sh
vault read database/creds/product
```

### Configure Vault policy
```sh
cat > product.hcl << EOF
path "database/creds/product" {
  capabilities = ["read"]
}
EOF
vault policy write product ./product.hcl
vault write auth/kubernetes/role/product \
    bound_service_account_names=product \
    bound_service_account_namespaces=default \
    policies=product \
    ttl=1h
```

### Edit `product.yaml`
```sh
vim product.yaml
# find the annotation that mentions the namespace `vault.hashicorp.com/namespace: "admin"` and delete that line
```

### Deploy `product-*` pod and check for `RUNNING` status
```sh
kubectl apply -f product.yaml
kubectl get po
```

### Exec into the pod and observe that the credentials dynamically change every ~30s
```sh
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[1].metadata.name')
watch -n 1 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```

### Clean up Database Secrets Engine
```sh
vault secrets disable database
```

### Delete pods
```sh
kubectl delete -f product.yaml
kubectl delete -f postgres.yaml
```

## Configure Static Database Roles

### Deploy Postgres database
```sh
kubectl apply -f postgres.yaml
kubectl get po
```

### Exec into `postgres-*` pod
```sh
PG_POD=$(kubectl get po -o json | jq -r '.items[0].metadata.name')
kubectl exec --stdin --tty $PG_POD -- /bin/bash

# Setup Static database credential
export PGPASSWORD=password
psql -U postgres -c "CREATE ROLE \"static-vault-user\" WITH LOGIN PASSWORD 'password';"

# Grant associated privileges for the role
psql -U postgres -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"static-vault-user\";"

# Confirm role attributes
psql -U postgres -c "\du"

# Exit pod
exit
```
<!-- ## Configure Static Database Roles
```sh
vault auth enable kubernetes
export TOKEN_REVIEW_JWT=$(kubectl get secret \
   $(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') \
   -o jsonpath='{ .data.token }' | base64 --decode)
export KUBE_CA_CERT=$(kubectl get secret \
   $(kubectl get serviceaccount vault -o jsonpath='{.secrets[0].name}') \
   -o jsonpath='{ .data.ca\.crt }' | base64 --decode)
export KUBE_HOST=$(kubectl config view --raw --minify --flatten \
   -o jsonpath='{.clusters[].cluster.server}')
vault write auth/kubernetes/config \
   token_reviewer_jwt="$TOKEN_REVIEW_JWT" \
   kubernetes_host="$KUBE_HOST" \
   kubernetes_ca_cert="$KUBE_CA_CERT"
```

## Enable and add database role -->

### Enable and configure database secrets engine
```sh
vault secrets enable database
export POSTGRES_IP=$(kubectl get service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
   postgres)
vault write database/config/postgresql \
    plugin_name=postgresql-database-plugin \
    allowed_roles="*" \
    connection_url="postgresql://{{username}}:{{password}}@${POSTGRES_IP}:5432/products?sslmode=disable" \
    username="postgres" \
    password="password"
```

### Create a static role
```sh
cat > rotation.sql << EOF
ALTER USER "{{name}}" WITH PASSWORD '{{password}}';
EOF
vault write database/static-roles/product \
    db_name=postgresql \
    rotation_statements=@rotation.sql \
    username="static-vault-user" \
    rotation_period=30
vault read database/static-creds/product
```

## Create policy and assocate with auth method
```sh
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
```

### Generate new `static-product.yaml` file
```sh
cat > static-product.yaml << EOF
---
apiVersion: v1
kind: Service
metadata:
  name: product
spec:
  selector:
    app: product
  ports:
    - name: http
      protocol: TCP
      port: 9090
      targetPort: 9090
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: product
automountServiceAccountToken: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: product
  labels:
    app: product
spec:
  replicas: 1
  selector:
    matchLabels:
      app: product
  template:
    metadata:
      labels:
        app: product
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "product"
        vault.hashicorp.com/agent-inject-secret-conf.json: "database/static-creds/product"
        vault.hashicorp.com/agent-inject-template-conf.json: |
          {
            "bind_address": ":9090",
            {{ with secret "database/static-creds/product" -}}
            "db_connection": "host=${POSTGRES_IP} port=5432 user={{ .Data.username }} password={{ .Data.password }} dbname=products sslmode=disable"
            {{- end }}
          }
    spec:
      serviceAccountName: product
      containers:
        - name: product
          image: hashicorpdemoapp/product-api:v0.0.14
          ports:
            - containerPort: 9090
          env:
            - name: "CONFIG_FILE"
              value: "/vault/secrets/conf.json"
          livenessProbe:
            httpGet:
              path: /health
              port: 9090
            initialDelaySeconds: 15
            timeoutSeconds: 1
            periodSeconds: 10
            failureThreshold: 30
EOF
```

### Check that the `host` value rendered properly with the AWS FQDN record
```sh
more static-product.yaml | grep host
```

### Deploy the product service with the static database role
```sh
kubectl apply -f static-product.yaml
kubectl get po
```

### Observe how the database password in the `product-*` pod dynamically changes every 30 seconds
```sh
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[1].metadata.name')
watch -n 1 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```
Hit `Ctrl+C` to stop.

### `Optional`: Open another terminal and watch the countdown of the static credential.  When the password is rotated, the database password rendered i the `product-*` pod  is changed at the same time
```
watch -n 1 vault read database/static-creds/postgresql
```
Hit `Ctrl+C` to stop and close terminal.

## Clean Up
```sh
cd ../../..
nohup terraform apply -auto-approve -parallelism=20 > apply.log &
```
Run `tail -f apply.log` to view the progress of the destroy

## Supporting docs
https://www.vaultproject.io/docs/agent/template#static-roles, specifically as it pertains to Static Roles, `If a secret has a rotation_period, such as a database static role, Vault Agent template will fetch the new secret as it changes in Vault. It does this by inspecting the secret's time-to-live (TTL).`
```