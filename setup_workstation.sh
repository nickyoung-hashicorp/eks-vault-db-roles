# Install Vault to use the CLI

export VAULT_VERSION=1.10.3 # Choose your desired Vault version
wget https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
unzip -j vault_*_linux_amd64.zip -d /usr/local/bin

# Setup Environment
echo "export VAULT_TOKEN=$(cat ~/eks-vault-db-roles/root_token)" >> ~/.bashrc
echo "export VAULT_ADDR=http://$(terraform output vault_ip):8200" >> ~/.bashrc
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