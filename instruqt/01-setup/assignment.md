---
slug: setup
id: dgyft2v99hv8
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

## Provision infrastructure using Terraform
```
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
sudo apt update -y && sudo apt install jq -y
```

Install Vault
```
./install_vault.sh
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
echo "export VAULT_TOKEN=$(cat ~/eks-vault-db-roles/root_token)" >> ~/.bashrc
echo "export VAULT_ADDR=http://$(terraform output -state=~/eks-vault-db-roles/terraform.tfstate vault_ip):8200" >> ~/.bashrc

# Remove files
rm -rf aws awscliv2.zip get_helm.sh vault_*_linux_amd64.zip

# Check that the environment variables were saved properly

source ~/.bashrc && cd ~/eks-vault-db-roles/
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

Clean up Database Secrets Engine and K8s objects
```
vault secrets disable database
kubectl delete -f ./yaml/product.yaml
kubectl delete -f ./yaml/postgres.yaml
```
Deleting the Postgres deployment can take a couple minutes.

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

Clean up Database Secrets Engine and K8s objects
```
vault secrets disable database
kubectl delete -f ./product-static.yaml
kubectl delete -f ./yaml/postgres.yaml
```
Deleting the Postgres pod can take a couple minutes.


Database Credentials from EKS Pod to RDS
========================================

Configure dynamic database role in Vault for the RDS instance
```
./configure_rds_dynamic_role.sh
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

Notice that there is no `postgres-*` pod running in EKS
```
kubectl get po
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
            "db_connection": "host=${RDS_ADDR} port=5432 user={{ .Data.username }} password={{ .Data.password }} dbname=products sslmode=disable"
            {{- end }}
          }
    spec:
      serviceAccountName: product
      containers:
        - name: product-rds
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

## SCRATCH

Login to Postgres RDS
```
psql -h $(terraform output rds-address) -p 5432 -U postgres products
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