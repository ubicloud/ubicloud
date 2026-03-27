#!/bin/bash
# Regenerates the Personal Access Token for the default dev account.
# Use when get-pat-token.sh fails with a decryption error (e.g. after
# the column encryption key changes).
#
# Usage: .devcontainer/scripts/rotate-pat-token.sh

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

  # Delete existing PAT(s) for this account+project so a fresh one can be created
  ApiKey.where(owner_table: "accounts", owner_id: account.id, project_id: project.id, used_for: "api").each do |old_pat|
    old_pat.destroy
    puts "Deleted old PAT #{old_pat.ubid}"
  end

  pat = ApiKey.create_personal_access_token(account, project: project)
  pat.unrestrict_token_for_project(project.id)
  puts "New PAT token: pat-#{pat.ubid}-#{pat.key}"
'
