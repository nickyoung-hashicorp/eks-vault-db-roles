# Install dependencies
sudo apt install -y curl gpg gnupg2 software-properties-common apt-transport-https lsb-release ca-certificates jq -y

# Install PostgreSQL client
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc|sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
echo "deb http://apt.postgresql.org/pub/repos/apt/ `lsb_release -cs`-pgdg main" |sudo tee  /etc/apt/sources.list.d/pgdg.list
sudo apt update -y
sudo apt install postgresql-13 postgresql-client-13 -y