#!/bin/bash
# Creates the default Ubicloud project with private_locations enabled
# and sets POSTGRES_SERVICE_PROJECT_ID in .env.rb.
#
# Usage: register-pg-project.sh

set -e

echo "=== Creating default project and account ==="

RACK_ENV=development bundle exec ruby -r ./loader -e '
  email = "dev@ubicloud.local"
  account = Account.first(email: email)
  unless account
    account = Account.create(email: email, status_id: 2)
  end
  puts "Account \"#{account.email}\" (id: #{account.id}, ubid: #{account.ubid})"

  project = account.projects_dataset.first(name: "default")
  unless project
    project = account.create_project_with_default_policy("default")
  end
  project.set_ff_private_locations(true)
  puts "Project \"#{project.name}\" (id: #{project.id}, ubid: #{project.ubid})"

  # Add POSTGRES_SERVICE_PROJECT_ID to .env.rb
  env_rb = ".env.rb"
  env_line = "ENV[\"POSTGRES_SERVICE_PROJECT_ID\"] = \"#{project.id}\""
  content = File.exist?(env_rb) ? File.read(env_rb) : ""
  if content.include?("POSTGRES_SERVICE_PROJECT_ID")
    content.gsub!(/^ENV\["POSTGRES_SERVICE_PROJECT_ID"\].*$/, env_line)
    File.write(env_rb, content)
  else
    File.open(env_rb, "a") { |f| f.puts env_line }
  end

  pat = ApiKey.first(owner_table: "accounts", owner_id: account.id, project_id: project.id, used_for: "api")
  unless pat
    pat = ApiKey.create_personal_access_token(account, project: project)
    pat.unrestrict_token_for_project(project.id)
  end

  puts "PAT token: pat-#{pat.ubid}-#{pat.key}"

  # Remove shared (non-project-specific) locations — this devcontainer is for
  # the Clickhouse environment which only uses the project-owned AWS location.
  shared = Location.where(project_id: nil).all
  if shared.any?
    shared.each(&:destroy)
    puts "Removed #{shared.count} shared location(s): #{shared.map(&:display_name).join(", ")}"
  end

'
