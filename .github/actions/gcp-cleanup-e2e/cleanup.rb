#!/usr/bin/env ruby
# frozen_string_literal: true

# Log-grep teardown of GCP resources created by the e2e suite.
#
# Each successful GCP create emits a `Clog.emit` log line into foreman.log
# of the form `"<key>":"<name>"` (or `"<key>":"<name>@<scope>"` for
# region/zone-scoped resources). We harvest the names per key and call
# `gcloud delete` for each one.
#
# GCP holds ghost references for minutes after a parent resource dies:
# tag bindings of deleted instances block tag value deletion, an
# undeleted value blocks its key, and lingering interface references
# block subnet and network deletion. A single immediate pass therefore
# fails for most of a wedged run's resources, so failed deletes are
# retried in dependency order across multiple passes with a pause in
# between. 404s count as already-deleted. Anything still alive after the
# last pass is reported loudly as LEAKED.
#
# Expects:
#   ENV["GCP_PROJECT_ID"]      -- project to operate against
#   ENV["FOREMAN_LOG"]         -- path to foreman.log (default: foreman.log)
#   gcloud is on PATH and already authenticated.

require "open3"

FOREMAN_LOG = ENV["FOREMAN_LOG"] || "foreman.log"
PROJECT = ENV.fetch("GCP_PROJECT_ID")
RETRY_PASSES = Integer(ENV["RETRY_PASSES"] || 3)
RETRY_SLEEP = Integer(ENV["RETRY_SLEEP"] || 75)

# Run a gcloud subcommand. Returns :ok, :gone (already deleted), or
# :failed, surfacing the first useful stderr line on failure.
def run_gcloud(args)
  stdout, stderr, status = Open3.capture3("gcloud", *args, "--quiet")
  print stdout unless stdout.empty?
  return :ok if status.success?
  return :gone if /NOT_FOUND|was not found|does not exist|404/i.match?(stderr)

  brief = stderr.lines.find { |l| /ERROR|FAILED|PERMISSION|RESOURCE|in use|exhausted/i.match?(l) } || stderr.lines.first
  puts "  WARN: gcloud #{args.join(" ")} failed: #{brief&.strip}"
  :failed
end

# Execute jobs ({desc:, args:}) in order; retry failures across passes.
def drain(jobs, passes: RETRY_PASSES, sleep_between: RETRY_SLEEP)
  pending = jobs
  remaining = passes
  while remaining.positive?
    failed = []
    pending.each do |job|
      puts job[:desc]
      failed << job if run_gcloud(job[:args]) == :failed
    end
    pending = failed
    return if pending.empty?
    remaining -= 1
    if remaining.positive?
      puts "#{pending.size} deletes failed; retrying in #{sleep_between}s (ghost references clear asynchronously)"
      sleep sleep_between
    end
  end

  puts "LEAKED: #{pending.size} resources survived #{passes} delete passes:"
  pending.each { |j| puts "  #{j[:desc]}" }
end

# Extract every unique value of `"key":"VALUE"` from foreman.log. Returns
# an empty array if the key never appears (zero matches is not an error).
def extract_names(key)
  return [] unless File.exist?(FOREMAN_LOG)
  pattern = /"#{Regexp.escape(key)}":"([^"]+)"/
  names = Set.new
  File.foreach(FOREMAN_LOG) do |line|
    line.scan(pattern) { |m| names << m.first }
  end
  names.to_a
end

# `name@scope` encoding: split on `@`. Skip malformed entries (no `@`)
# rather than passing the full string as both name and scope (which would
# produce silently wrong delete args). Returns [name, scope] or nil.
def split_scoped(entry)
  return nil unless entry.include?("@")
  name, scope = entry.split("@", 2)
  return nil if name.empty? || scope.empty?
  [name, scope]
end

def section(label, names)
  if names.empty?
    puts "No #{label} found in foreman.log"
    return false
  end
  puts "#{label}:"
  names.each { |n| puts "  #{n}" }
  true
end

abort "set GCP_PROJECT_ID" if PROJECT.to_s.empty?

unless File.exist?(FOREMAN_LOG)
  puts "#{FOREMAN_LOG} not found; nothing to clean up"
  exit 0
end

# Build the delete queue in dependency order:
#   1. instances              (hold static IPs and tag bindings)
#   2. firewall policy associations  (block fw policy delete)
#   3. firewall policies      (must be gone before VPC delete)
#   4. tag values, then tag keys (values must be empty before keys; firewall
#      tag keys reference the VPC via purpose_data so they must clear first)
#   5. static IPs             (now unattached)
#   6. subnets                (block VPC delete)
#   7. VPCs                   (need subnets + fw policies gone)
#   8. service accounts       (independent)
#   9. GCS buckets            (independent)
jobs = []

instances = extract_names("gcp_instance_created")
if section("GCE instances", instances)
  instances.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed instance entry: #{entry}" unless parts
    name, zone = parts
    jobs << {desc: "Deleting instance #{name} in #{zone}",
             args: ["compute", "instances", "delete", name, "--zone=#{zone}", "--project=#{PROJECT}"]}
  end
end

assocs = extract_names("gcp_firewall_policy_association_created")
if section("Firewall policy associations", assocs)
  assocs.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed association entry: #{entry}" unless parts
    assoc_name, policy_name = parts
    jobs << {desc: "Removing association #{assoc_name} from #{policy_name}",
             args: ["compute", "network-firewall-policies", "associations", "delete",
               "--firewall-policy=#{policy_name}", "--name=#{assoc_name}",
               "--project=#{PROJECT}", "--global-firewall-policy"]}
  end
end

fwpolicies = extract_names("gcp_firewall_policy_created")
if section("Firewall policies", fwpolicies)
  fwpolicies.each do |policy|
    jobs << {desc: "Deleting firewall policy #{policy}",
             args: ["compute", "network-firewall-policies", "delete", policy,
               "--project=#{PROJECT}", "--global"]}
  end
end

tag_values = extract_names("gcp_tag_value_created")
if section("Tag values", tag_values)
  tag_values.each do |tv|
    jobs << {desc: "Deleting tag value #{tv}",
             args: ["resource-manager", "tags", "values", "delete", tv]}
  end
end

tag_keys = extract_names("gcp_tag_key_created")
if section("Tag keys", tag_keys)
  tag_keys.each do |tk|
    jobs << {desc: "Deleting tag key #{tk}",
             args: ["resource-manager", "tags", "keys", "delete", tk]}
  end
end

ips = extract_names("gcp_static_ip_created")
if section("Static IPs", ips)
  ips.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed static IP entry: #{entry}" unless parts
    ip_name, region = parts
    jobs << {desc: "Releasing IP #{ip_name} in #{region}",
             args: ["compute", "addresses", "delete", ip_name, "--region=#{region}", "--project=#{PROJECT}"]}
  end
end

subnets = extract_names("gcp_subnet_created")
if section("Subnets", subnets)
  subnets.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed subnet entry: #{entry}" unless parts
    subnet_name, region = parts
    jobs << {desc: "Deleting subnet #{subnet_name} in #{region}",
             args: ["compute", "networks", "subnets", "delete", subnet_name, "--region=#{region}", "--project=#{PROJECT}"]}
  end
end

vpcs = extract_names("gcp_vpc_created")
if section("VPC networks", vpcs)
  vpcs.each do |vpc|
    jobs << {desc: "Deleting VPC #{vpc}",
             args: ["compute", "networks", "delete", vpc, "--project=#{PROJECT}"]}
  end
end

sas = extract_names("gcp_service_account_created")
if section("Service accounts", sas)
  sas.each do |sa|
    jobs << {desc: "Deleting SA #{sa}",
             args: ["iam", "service-accounts", "delete", sa, "--project=#{PROJECT}"]}
  end
end

buckets = extract_names("gcp_gcs_bucket_created")
if section("GCS buckets", buckets)
  buckets.each do |bucket|
    jobs << {desc: "Deleting bucket gs://#{bucket}",
             args: ["storage", "rm", "-r", "gs://#{bucket}", "--project=#{PROJECT}"]}
  end
end

drain(jobs)
