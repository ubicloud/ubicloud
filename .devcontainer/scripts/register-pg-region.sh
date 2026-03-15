#!/bin/bash
# Registers a single AWS region for PostgreSQL development in the Ubicloud
# database: creates a private location with credentials, fetches the latest
# AMI IDs from the CI pipeline, and updates the AMI rows in the DB.
#
# Usage: register-pg-region.sh REGION ASSUME_ROLE
#   REGION:      AWS region to register (e.g. us-west-2)
#   ASSUME_ROLE: ARN of the IAM role to assume for AWS access

set -e

REPO="ClickHouse/postgres-vm-images"

# Fetch the latest AMI ID from the CI pipeline.
# Prints only the AMI ID to stdout; all informational messages go to stderr.
fetch_ami() {
  local region="$1"
  local arch="$2"

  local run_id
  # Fetch the latest successful build run for the PostgreSQL VM Image workflow
  run_id=$(gh api "repos/${REPO}/actions/runs?branch=main&status=success&per_page=20" \
    --jq '.workflow_runs[] | select(.name == "Build PostgreSQL VM Image") | .id' | head -1)

  if [ -z "$run_id" ]; then
    echo "Error: No successful build run found" >&2
    return 1
  fi

  # Fetch the latest job for the architecture
  local job_id
  job_id=$(gh api "repos/${REPO}/actions/runs/${run_id}/jobs?per_page=50" \
    --jq ".jobs[] | select(.name | test(\"${arch}\")) | .id" | head -1)

  if [ -z "$job_id" ]; then
    echo "Error: No job found for arch ${arch}" >&2
    return 1
  fi

  # Fetch the AMI ID from the job logs
  local ami_id
  ami_id=$(gh api "repos/${REPO}/actions/jobs/${job_id}/logs" 2>/dev/null \
    | grep -oP "Copied AMI to ${region}: \Kami-[0-9a-f]+")

  if [ -z "$ami_id" ]; then
    echo "Error: No AMI found for region ${region}" >&2
    return 1
  fi

  echo "AMI: ${ami_id} (region: ${region}, arch: ${arch}, run: ${run_id})" >&2
  echo "$ami_id"
}

REGION="${1:?Usage: $0 REGION ASSUME_ROLE}"
ASSUME_ROLE="${2:?Usage: $0 REGION ASSUME_ROLE}"

echo "=== Registering region ${REGION} ==="

# Create private location in Ubicloud DB
echo ""
echo "--- Creating private location ---"

RACK_ENV=development bundle exec ruby -r ./loader -e '
  region = ARGV[0]
  assume_role = ARGV[1]
  project = Project.first(name: "default")

  display_name = "aws-#{region}"
  loc = Location.first(project_id: project.id, display_name: display_name)
  if loc
    puts "Location \"#{display_name}\" already exists (id: #{loc.id})"
  else
    loc = Location.create(
      name: region,
      display_name: display_name,
      ui_name: display_name,
      visible: true,
      provider: "aws",
      project_id: project.id
    )
    LocationCredential.create(access_key: "dummy", secret_key: "dummy") { it.id = loc.id }
    puts "Created location \"#{display_name}\" (id: #{loc.id})"
  end

  loc.location_credential.update(access_key: nil, secret_key: nil, assume_role: assume_role)
  puts "Updated credential with assume_role: #{assume_role}"
' -- "$REGION" "$ASSUME_ROLE"

# Fetch latest AMIs from CI pipeline
echo ""
echo "--- Fetching latest PostgreSQL AMIs ---"

AMI_X64=$(fetch_ami "$REGION" x64)
AMI_ARM64=$(fetch_ami "$REGION" arm64)

echo ""
echo "x64:   ${AMI_X64}"
echo "arm64: ${AMI_ARM64}"

# Update AMI rows in the database
echo ""
echo "--- Updating AMIs in database ---"

RACK_ENV=development bundle exec ruby -r ./loader -e '
  region = ARGV[0]
  ami_x64 = ARGV[1]
  ami_arm64 = ARGV[2]

  updated_x64 = PgAwsAmi.where(aws_location_name: region, arch: "x64").update(aws_ami_id: ami_x64)
  updated_arm64 = PgAwsAmi.where(aws_location_name: region, arch: "arm64").update(aws_ami_id: ami_arm64)

  puts "Updated x64:   #{updated_x64} row(s) -> #{ami_x64}"
  puts "Updated arm64: #{updated_arm64} row(s) -> #{ami_arm64}"
' -- "$REGION" "$AMI_X64" "$AMI_ARM64"
