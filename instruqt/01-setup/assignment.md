---
slug: setup
id: zsqgmr1yodrw
type: challenge
title: Setup the environment
teaser: This challenge walks through deploying and configuring a single Vault node,
  EKS cluster, and RDS instance
notes:
- type: text
  contents: |
    Setting up your environment...
tabs:
- title: Shell 1
  type: terminal
  hostname: workstation
- title: Shell 2
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
1) Preparation
==============

## Provision infrastructure using Terraform
```
cd /root/eks-vault-db-roles
chmod +x *.sh
./0_setup_workstation
terraform init && nohup terraform apply -auto-approve -parallelism=20 > apply.log &
```

The EKS cluster and RDS database can take 15-20 minutes to provision, so can run `tail -f apply.log` to check on the real-time status of the apply after you see the `nohup: ignoring input and redirecting stderr to stdout` message in the terminal.

Press `Ctrl+C` to cancel out of the `tail` command once the apply is complete.

## Configure Vault

Create file with the RDS address and copy to the EC2 instance
```
echo "$(terraform output rds_address)" >> rds_address
scp -i ssh-key.pem ./rds_address ubuntu@$(terraform output vault_ip):~/rds_address
```

SSH to the EC2 instance
```
ssh -i ssh-key.pem ubuntu@$(terraform output vault_ip)
```

Update packages and install `jq`
```
sudo su
apt update -y
```

Install Vault
```
./install_vault.sh
```

*Optional*: Install PostgreSQL client for `Static Roles - EKS Pod to RDS` section
```
./install_postgres_client.sh
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
scp -i ssh-key.pem ubuntu@$(terraform output vault_ip):~/root_token .
```

## Setup Local Workstation

Save Vault environment variables
```
export VAULT_TOKEN=$(cat ~/eks-vault-db-roles/root_token)
export VAULT_ADDR=http://$(terraform output vault_ip):8200
export AWS_DEFAULT_REGION=us-west-2
export EKS_CLUSTER=eks-rds-demo

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

Allow all traffic inbound to the EKS cluster for ease of demonstration
```
export EKS_SG=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values=eks-cluster* | jq -r '.SecurityGroups[] | .GroupId')

aws ec2 authorize-security-group-ingress \
    --group-id ${EKS_SG} \
    --protocol all \
    --port -1 \
    --cidr 0.0.0.0/0 | jq -r '.Return'
```
A result of `true` means this completed as expected.


## Install the Vault Agent

Install Vault Agent on EKS using Helm
```
./install_agent.sh
```
A result showing `pod/vault-agent-injector-... condition met` is an indication the pod is ready.

## Configure Vault's Kubernetes Auth Method

Configure Kubernetes Auth Method on Vault
```
./enable_auth.sh
```

2) Dynamic Credentials - EKS only
=================================

Deploy `postgres-*` database pod and check for `RUNNING` status
```
kubectl apply -f ./yaml/postgres.yaml && kubectl wait po --for=condition=Ready -l app=postgres
```

Configure dynamic database role in Vault
```
./1_dynamic_role.sh
```

Test generating dynamic credentials
```
vault read database/creds/product
```

Configure Vault policy
```
./2_dynamic_policy.sh
```

Deploy the `product` pod and check for `RUNNING` status
```
kubectl apply -f ./yaml/product.yaml && kubectl wait po --for=condition=Ready -l app=product
```

Save `product` pod name
```
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[1].metadata.name') && echo $PRODUCT_POD
```

Exec into the pod and observe that the credentials dynamically change every ~20s
```
watch -n 2 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```
Press `Ctrl+C` to stop.

Clean up Database Secrets Engine and K8s objects
```
vault secrets disable database
kubectl delete -f ./yaml/product.yaml
kubectl delete -f ./yaml/postgres.yaml
```
Deleting the Postgres deployment can take up to a couple minutes.

3) Static Role - EKS only
=========================

Deploy Postgres database
```
kubectl apply -f ./yaml/postgres.yaml && kubectl wait po --for=condition=Ready -l app=postgres
```

Exec into `postgres` pod to setup static user for Vault
```
PG_POD=$(kubectl get po -o json | jq -r '.items[0].metadata.name') && echo $PG_POD
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

Configure static database role in Vault
```
./3_static_role.sh
```
If this fails, wait several seconds and re-run this script.  Sometimes it can take several seconds for the Postgres database to respond to the Vault configuration setup.

Test viewing the static credentials
```
vault read database/static-creds/product-static
```

Configure Vault policy
```
./4_static_policy.sh
```

Generate a new `product-static.yaml` file
```
export POSTGRES_IP=$(kubectl get service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' postgres) && echo $POSTGRES_IP
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

Check that the `host` value rendered properly with the AWS FQDN record of the Elastic Load Balancer
```
more product-static.yaml | grep host
```

Deploy the product service with the static database role
```
kubectl apply -f product-static.yaml && kubectl wait po --for=condition=Ready -l app=product-static
```

Observe how the database password in the `product-` pod dynamically changes every ~20 seconds
```
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[1].metadata.name')
echo $PRODUCT_POD
watch -n 2 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```
Press `Ctrl+C` to stop.

Optional: Open a second terminal and watch the countdown of the static credential.  When the password is rotated, the database psasword rendered in the `product` pod is chnaged at the same time
```
watch -n 2 vault read database/static-creds/product-static
```
Press `Ctrl+C` to stop and return to the first terminal.

Clean up Database Secrets Engine and K8s objects
```
vault secrets disable database
kubectl delete -f ./product-static.yaml
kubectl delete -f ./yaml/postgres.yaml
```
Deleting the Postgres pod can take a couple minutes.


4) Dynamic Credentials - EKS Pod to RDS
=======================================

Configure dynamic database role in Vault for the RDS instance
```
./5_rds_dynamic_role.sh
```

Test generating dynamic credentials on the RDS database
```
vault read database/creds/product
```

Configure Vault policy
```
./6_rds_dynamic_policy.sh
```

Deploy the `product-*` pod and check for `RUNNING` status
```
kubectl apply -f ./yaml/product.yaml
```

Notice that there is no `postgres-*` pod running in EKS
```
kubectl get po
```

Save `product` pod name
```
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[0].metadata.name') && echo $PRODUCT_POD
```

Exec into the pod and observe that the credentials dynamically change every ~20s
```
watch -n 2 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```

Clean up Database Secrets Engine and K8s objects
```
vault secrets disable database
kubectl delete -f ./yaml/product.yaml
```

5) Static Role - EKS Pod to RDS
================================

# Setup Postgres (RDS) with static user

Login to the Postgres database running in RDS
```
psql --host=$(cat rds_address) --port=5432 --username=postgres --password --dbname=products
```
Type `password` then press **Enter** when prompted.

Setup static user for Vault
```
export PGPASSWORD=password
CREATE USER "static-vault-user" WITH PASSWORD 'password';
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "static-vault-user";
\du
logout
\q
```

Configure static database role in Vault
```
./7_rds_static_role.sh
```

Test viewing the static credentials
```
vault read database/static-creds/product-static
```

Configure Vault policy
```
./8_rds_static_policy.sh
```

Generate a new `product-static.yaml` file
```
export RDS_ADDR=$(terraform output rds_address) && echo $POSTGRES_IP
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
            "db_connection": "host=${RDS_ADDR} port=5432 user={{ .Data.username }} password={{ .Data.password }} dbname=products sslmode=disable"
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

Check that the `host` value rendered properly with the AWS FQDN record of the RDS endpoint
```
more product-static.yaml | grep host=terraform
```

Deploy the product service with the static database role
```
kubectl apply -f product-static.yaml && kubectl wait po --for=condition=Ready -l app=product-static
```

Observe how the database password in the `product` pod dynamically changes every ~20 seconds
```
PRODUCT_POD=$(kubectl get po -o json | jq -r '.items[0].metadata.name')
echo $PRODUCT_POD
watch -n 2 kubectl exec $PRODUCT_POD  -- cat /vault/secrets/conf.json
```
Press `Ctrl+C` to stop.

Optional: Open a second terminal and watch the countdown of the static credential.  When the password is rotated, the database psasword rendered in the `product` pod is chnaged at the same time
```
watch -n 2 vault read database/static-creds/product-static
```
Press `Ctrl+C` to stop.

Optional: Open a second terminal, access the EC2 instance, and attempt to login to the Postgres database using the static user
```
ssh -i ssh-key.pem ubuntu@$(terraform output vault_ip)
```

Login to Vault
```
export VAULT_ADDR=http://127.0.0.1:8200
vault login $(cat root_token)
```

Retrieve current Static Credentials
```
vault read database/static-creds/product-static
read PG_USER PG_PASSWORD < <(echo $(vault read -format=json database/static-creds/product-static | jq -r '.data.username, .data.password') )
echo $PG_USER
echo $PG_PASSWORD

# Login using PostgreSQL Client
PGPASSWORD=$PG_PASSWORD psql --host=$(cat rds_address) --port=5432 --username=$PG_USER --dbname=products
```

List users the exit
```
\du
```
Press `q` to quit.

Quit out of Postgres
```
logout
\q
```

After the 20s rotation period, attempting to login with the same password should fail
```
PGPASSWORD=$PG_PASSWORD psql --host=$(cat rds_address) --port=5432 --username=$PG_USER --dbname=products
```

Test once more by getting the current credentials and logging in
```
read PG_USER PG_PASSWORD < <(echo $(vault read -format=json database/static-creds/product-static | jq -r '.data.username, .data.password') )
echo $PG_USER
echo $PG_PASSWORD

# Login using PostgreSQL Client
PGPASSWORD=$PG_PASSWORD psql --host=$(cat rds_address) --port=5432 --username=$PG_USER --dbname=products
```

Quit out of Postgres
```
logout
\q
```

Exit from the EC2 instance
```
exit
```

Clean up Database Secrets Engine and K8s objects
```
vault secrets disable database
kubectl delete -f ./product-static.yaml
```

6) Clean Up
============

## Destroy Infrastructure
```
nohup terraform destroy -auto-approve -parallelism=20 > apply.log &
```

Alternatively, simply click the `Check` button to complete the challenge, followed by the `Stop` button to complete the Instruqt track.