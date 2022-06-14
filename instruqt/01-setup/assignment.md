---
slug: setup
id: uekdsy0im5vc
type: challenge
title: Setup the environment
teaser: This challenge walks through deploying and configuring a single Vault node,
  EKS cluster, and RDS instance
notes:
- type: text
  contents: |
    Setting up your environment...
tabs:
- title: Shell
  type: terminal
  hostname: workstation
- title: Text Editor
  type: code
  hostname: workstation
  path: /root/workspace
- title: Cloud Consoles
  type: service
  hostname: cloud-client
  path: /
  port: 80
difficulty: basic
timelimit: 86400
---
Deploy Vault, EKS, and RDS
==========================

## Clone repository and provision.
```
git clone https://github.com/nickyoung-hashicorp/eks-vault-db-roles.git
cd eks-vault-db-roles
terraform init && nohup terraform apply -auto-approve -parallelism=20 > apply.log &
```

The EKS cluster and RDS database can take 15-20 minutes to provision, so can run `tail -f apply.log` to check on the real-time status of the apply after you see the `nohup: ignoring input and redirecting stderr to stdout` message in the terminal.

Press `Ctrl+C` to cancel out of the `tail` command once the apply is complete.

## Configure Vault

SSH to the EC2 instance
```
ssh -i ssh-key.pem ubuntu@$(terraform output vault_ip)
```

Update packages and install `jq`
```
sudo su
apt update -y && apt install jq -y
```

Install Vault
```
./install_vault.sh
sleep 5
export VAULT_ADDR=http://127.0.0.1:8200
vault operator init -format=json -key-shares=1 -key-threshold=1 > /home/ubuntu/init.json
vault operator unseal $(cat /home/ubuntu/init.json | jq -r '.unseal_keys_b64[0]')
cat init.json | jq -r '.root_token' > root_token
```

Exit from root
```
exit
```

Exit from the EC2 instance
```
exit
```

Copy root token from the EC2 instance to the local workstation
```
scp -i ssh-key.pem ubuntu@$(terraform output vault_ip):/home/ubuntu/root_token .
```

## Setup Local Workstation

Install Vault to use the CLI
```
# Make scripts executable
chmod +x *.sh

# Download and install Vault
export VAULT_VERSION=1.10.3 # Choose your desired Vault version
wget https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
unzip -j vault_*_linux_amd64.zip -d /usr/local/bin

# Setup Environment
echo "export VAULT_TOKEN=$(cat /root/workspace/eks-vault-db-roles/root_token)" >> ~/.bashrc
echo "export VAULT_ADDR=http://$(terraform output -state=/root/workspace/eks-vault-db-roles/terraform.tfstate vault_ip):8200" >> ~/.bashrc
echo "export AWS_DEFAULT_REGION=us-west-2" >> ~/.bashrc
echo "export EKS_CLUSTER=eks-rds-demo"  >> ~/.bashrc

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

# Check that the environment variables were saved properly
```
source ~/.bashrc && cd eks-vault-db-roles/
echo $VAULT_TOKEN
echo $VAULT_ADDR
echo $AWS_DEFAULT_REGION
echo $EKS_CLUSTER
```

Configure `kubectl`
```
aws eks --region ${AWS_DEFAULT_REGION} update-kubeconfig --name ${EKS_CLUSTER}
```

Test EKS cluster
```
kubectl get po -A
```
If you see pods running in the `kube-system` namespace, you are ready to go.

## Install the Vault Agent

Install Vault Agent on EKS using Helm
```
./install_agent.sh
```

Check `vault-agent-injector-*` pod for `RUNNING` status
```
kubectl wait po --for=condition=Ready -l app.kubernetes.io/instance=vault
```

## Configure Vault's Kubernetes Auth Method

Configure Kubernetes Auth Method on Vault
```
./enable_auth.sh
```

Deploy Postgres Pod, Configure DB Secrets Engine
================================================

Deploy `postgres-*` database pod and check for `RUNNING` status
```
kubectl apply -f ./yaml/postgres.yaml
kubectl wait po --for=condition=Ready -l app=postgres
```

Configure dynamic database role in Vault
```
./configure_dynamic_role.sh
```
If this fails with an error that looks like `* error creating database object: error verifying connection: dial tcp: lookup a986ca57f20914c29b53f61ff0b7d960-2128898780.us-west-2.elb.amazonaws.com on 127.0.0.53:53: no such host`, you can create a security group associated with the EKS cluster that allows inbound traffic from anywhere to quickly allow the connection.

Test generating dynamic credentials
```
vault read database/creds/product
```

Configure Vault policy
```
./configure_dynamic_policy.sh
```

Demonstrate Dynamic Database Credentials within EKS
===================================================

Deploy the `product-*` pod and check for `RUNNING` status
```
kubectl apply -f ./yaml/product.yaml
kubectl wait po --for=condition=Ready -l app=product
```

Save `product` pod name
```
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[1].metadata.name')
echo $PRODUCT_POD
```

Exec into the pod and observe that the credentials dynamically change every ~20s
```
watch -n 2 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```
Press `Ctrl+C` to stop.

Clean up Database Secrets Engine
```
vault secrets disable database
```

Delete pods
```
kubectl delete -f ./yaml/product.yaml
kubectl delete -f ./yaml/postgres.yaml
```

Demonstrate Static Roles within EKS
===================================

Deploy Postgres database
```
kubectl apply -f ./yaml/postgres.yaml
kubectl wait po --for=condition=Ready -l app=postgres
```

Exec into `postgres-*` pod to setup static user for Vault
```
PG_POD=$(kubectl get po -o json | jq -r '.items[0].metadata.name')
echo $PG_POD
kubectl exec --stdin --tty $PG_POD -- /bin/bash
```

Setup static user for Vault
```
# Setup Static database credential
export PGPASSWORD=password

psql -U postgres -c "CREATE ROLE \"static-vault-user\" WITH LOGIN PASSWORD 'password';"

# Grant associated privileges for the role

psql -U postgres -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO \"static-vault-user\";"

# Confirm role attributes
psql -U postgres -c "\du"

# Exit the pod
exit
```

Configure dynamic database role in Vault
```
./configure_static_role.sh
```

Test viewing the static credentials
```
vault read database/static-creds/product-static
```

Configure Vault policy
```
./configure_static_policy.sh
```

Generate a new `product-static.yaml` file
```
cat > product-static.yaml << EOF
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
  name: product-static
  labels:
    app: product-static
spec:
  replicas: 1
  selector:
    matchLabels:
      app: product-static
  template:
    metadata:
      labels:
        app: product-static
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "product-static"
        vault.hashicorp.com/agent-inject-secret-conf.json: "database/static-creds/product"
        vault.hashicorp.com/agent-inject-template-conf.json: |
          {
            "bind_address": ":9090",
            {{ with secret "database/static-creds/product-static" -}}
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

Check that the `host` value rendered properly with the AWS FQDN record
```
more product-static.yaml | grep host
```

Deploy the product service with the static database role
```
kubectl apply -f product-static.yaml
kubectl wait po --for=condition=Ready -l app=product-static
```

Observe how the database password in the `product-` pod dynamically changes every 30 seconds
```
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[1].metadata.name')
echo $PRODUCT_POD
watch -n 2 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```
Press `Ctrl+C` to stop.

Optional: Open a second terminal and watch the countdown of the static credential.  When the password is rotated, the database psasword rendered in the `product-` pod is chnaged at the same time
```
watch -n 2 vault read database/static-creds/product-static
```
Press `Ctrl+C` to stop and return to the first terminal.

Clean up Database Secrets Engine
```
vault secrets disable database
```

Delete pods
```
kubectl delete -f ./yaml/product.yaml
kubectl delete -f ./yaml/postgres.yaml
```

Database Credentials from EKS Pod to RDS
========================================

Configure dynamic database role in Vault for the RDS instance
```
./configure_rds.sh
```

Test generating dynamic credentials
```
vault read database/creds/product
```

Configure Vault policy
```
./configure_dynamic_policy.sh
```

Deploy the `product-*` pod and check for `RUNNING` status
```
kubectl apply -f ./yaml/product.yaml
```

Save `product` pod name
```
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[0].metadata.name')
echo $PRODUCT_POD
```

Exec into the pod and observe that the credentials dynamically change every ~20s
```
watch -n 2 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```
Notice the error and no rendering of secrets. Press `Ctrl+C` to stop.

Delete the `product` pod
```
kubectl delete -f ./yaml/product.yaml
```

Generate an ExternalName service definition
```
export RDS_ADDR=$(terraform output rds-address)
cat > rds-postgres.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: rds-postgres
spec:
  type: ExternalName
  externalName: ${RDS_ADDR}
EOF
```

Check to ensure the RDS endpoint rendered properly in the YAML definition
```
more rds-postgres.yaml | grep externalName
```

Deploy the `ExternalName` service
```
kubectl apply -f rds-postgres.yaml
kubectl get svc | grep rds-postgres
```

Generate a new `product-rds.yaml` file
```
cat > product-rds.yaml << EOF
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
  name: product-rds
  labels:
    app: product-rds
spec:
  replicas: 1
  selector:
    matchLabels:
      app: product-rds
  template:
    metadata:
      labels:
        app: product-rds
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "product-rds"
        vault.hashicorp.com/agent-inject-secret-conf.json: "database/static-creds/product"
        vault.hashicorp.com/agent-inject-template-conf.json: |
          {
            "bind_address": ":9090",
            {{ with secret "database/static-creds/product-static" -}}
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

Check that the `host` value rendered properly with the AWS FQDN record
```
more product-rds.yaml | grep host
```

Deploy the product service with the RDS database role
```
kubectl apply -f product-rds.yaml
kubectl wait po --for=condition=Ready -l app=product-rds
```