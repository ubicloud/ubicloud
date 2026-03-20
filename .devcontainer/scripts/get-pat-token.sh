#!/bin/bash
# Prints the Personal Access Token for the default dev account.
# If the account or PAT does not exist, run register-pg-project.sh first.
#
# Usage: .devcontainer/scripts/get-pat-token.sh

set -e

RACK_ENV=development bundle exec ruby -r ./loader -e '
  email = "dev@ubicloud.local"
  account = Account.first(email: email)
  if account.nil?
    puts "ERROR: Account \"#{email}\" not found. Run .devcontainer/scripts/register-pg-project.sh first."
    exit 1
  end

  project = account.projects_dataset.first(name: "default")
  if project.nil?
    puts "ERROR: Project \"default\" not found. Run .devcontainer/scripts/register-pg-project.sh first."
    exit 1
  end

  pat = ApiKey.first(owner_table: "accounts", owner_id: account.id, project_id: project.id, used_for: "api")
  if pat.nil?
    puts "ERROR: No PAT found. Run .devcontainer/scripts/register-pg-project.sh first."
    exit 1
  end

  puts "pat-#{pat.ubid}-#{pat.key}"
'
