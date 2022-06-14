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

The EKS cluster and RDS database can take 15-20 minutes to provision, so can run `tail -f apply.log` to check on the real-time status of the apply.  Press `Ctrl+C` to cancel out of the `tail` command.

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
cd ./scripts
chmod +x *.sh
setup_workstation.sh
```

Check that the environment variables were saved properly
```
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
kubectl apply -f ../yaml/postgres.yaml
kubectl wait po --for=condition=Ready -l app=postgres
```

Add database role to Vault
```
./configure_dynamic_role.sh
```
If this fails with an error that looks like `* error creating database object: error verifying connection: dial tcp: lookup a986ca57f20914c29b53f61ff0b7d960-2128898780.us-west-2.elb.amazonaws.com on 127.0.0.53:53: no such host`, you can create a security group associated with the EKS cluster that allows inbound traffic from anywhere to quickly allow the connection.

### Test generating dynamic credentials
```
vault read database/creds/product
```

### Configure Vault policy
```
./configure_dynamic_policy.sh
```

Demonstrate Dynamic Database Credentials within EKS
===================================================

Deploy the `product-*` pod and check for `RUNNING` status
```
kubectl apply -f ../yaml/product.yaml
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

Clean up Database Secrets Engine and Kubernetes Auth Method
```
vault secrets disable database
vault auth disable kubernetes
```

Delete pods
```
kubectl delete -f ../yaml/product.yaml --grace-period 0 --force
kubectl delete -f ../yaml/postgres.yaml --grace-period 0 --force
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

# Exit pod
exit
```

Enable Kubernetes authentication method
```
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