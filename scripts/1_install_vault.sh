#!/bin/bash -v

echo "Installing Vault with a file backend"

wget https://releases.hashicorp.com/vault/1.10.3/vault_1.10.3_linux_amd64.zip
unzip -j vault_*_linux_amd64.zip -d /usr/local/bin

groupadd vault
useradd -r -g vault -d /usr/local/vault -m -s /sbin/nologin -c "Vault user" vault

mkdir /etc/vault /etc/ssl/vault /mnt/vault
chown vault.root /etc/vault /etc/ssl/vault /mnt/vault
chmod 750 /etc/vault /etc/ssl/vault
chmod 700 /usr/local/vault

cat <<EOF | sudo tee /etc/vault/config.hcl
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}
backend "file" {
  path = "/mnt/vault/data"
}
disable_mlock = true
ui = true
EOF

cat <<EOF | sudo tee /etc/systemd/system/vault.service
[Unit]
Description="HashiCorp Vault - A tool for managing secrets"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault/config.hcl
StartLimitIntervalSec=60

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/vault server -config=/etc/vault/config.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
TimeoutStopSec=30s
Restart=on-failure
RestartSec=5
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 0644 /etc/systemd/system/vault.service

echo "Starting the Vault service..."
sudo systemctl start vault

sleep 5

export VAULT_ADDR=http://127.0.0.1:8200

echo "Initializing Vault"
vault operator init -format=json -key-shares=1 -key-threshold=1 > init.json

echo "Unsealing Vault"
vault operator unseal $(cat init.json | jq -r '.unseal_keys_b64[0]')

echo "Saving root token as file: root_token"
cat init.json | jq -r '.root_token' > root_token

echo "Installation complete"