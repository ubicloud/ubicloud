#!/bin/bash
set -euxo pipefail

# Stop the default PostgreSQL cluster on the runner if it exists
sudo -u postgres pg_dropcluster 16 main --stop || true
# Install PostgreSQL. The runner image already has all of its dependencies,
# so update only the package list of the PostgreSQL repository.
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
sudo apt-get update -o Dir::Etc::sourcelist=sources.list.d/pgdg.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
sudo NEEDRESTART_SUSPEND=1 apt-get install -y postgresql-17 postgresql-client-17
# Allow runner user to access PostgreSQL
echo 'runner_map runner postgres
runner_map runner clover
runner_map runner clover_password' | sudo tee -a /etc/postgresql/17/main/pg_ident.conf > /dev/null
sudo sed -i '1i local   all   all   peer map=runner_map' /etc/postgresql/17/main/pg_hba.conf
sudo systemctl restart postgresql
until pg_isready -q; do sleep 1; done
