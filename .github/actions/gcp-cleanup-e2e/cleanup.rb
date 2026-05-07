#!/usr/bin/env ruby
# frozen_string_literal: true

# Log-grep teardown of GCP resources created by the e2e suite.
#
# Each successful GCP create emits a `Clog.emit` log line into foreman.log
# of the form `"<key>":"<name>"` (or `"<key>":"<name>@<scope>"` for
# region/zone-scoped resources). We harvest the names per key and call
# `gcloud delete` for each one. Deletes are best-effort: --quiet swallows
# 404s from resources already cleaned up by a prior run, and any other
# failure is logged but does not abort the rest of the teardown.
#
# Cancellation-safe: a strand killed mid-cleanup leaves resources behind,
# but every future run's foreman.log carries the names it created, so the
# next teardown picks them up. Resources from cancelled-mid-create runs
# whose foreman.log is no longer available are not handled here -- they
# need manual cleanup, same as the AWS path.
#
# Expects:
#   ENV["GCP_PROJECT_ID"]      -- project to operate against
#   ENV["FOREMAN_LOG"]         -- path to foreman.log (default: foreman.log)
#   gcloud is on PATH and already authenticated.

FOREMAN_LOG = ENV["FOREMAN_LOG"] || "foreman.log"
PROJECT = ENV.fetch("GCP_PROJECT_ID")

# Run a gcloud subcommand. Suppresses stderr because --quiet still chatters
# about 404s; we treat any non-zero exit as a soft failure and report.
def gcloud(*args)
  ok = system("gcloud", *args, "--quiet", out: $stdout, err: File::NULL)
  puts "  WARN: gcloud #{args.join(" ")} returned non-zero" unless ok
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

# Delete in dependency order:
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

instances = extract_names("gcp_instance_created")
if section("GCE instances", instances)
  instances.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed instance entry: #{entry}" unless parts
    name, zone = parts
    puts "Deleting instance #{name} in #{zone}"
    gcloud("compute", "instances", "delete", name, "--zone=#{zone}", "--project=#{PROJECT}")
  end
end

assocs = extract_names("gcp_firewall_policy_association_created")
if section("Firewall policy associations", assocs)
  assocs.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed association entry: #{entry}" unless parts
    assoc_name, policy_name = parts
    puts "Removing association #{assoc_name} from #{policy_name}"
    gcloud("compute", "network-firewall-policies", "associations", "delete",
      "--firewall-policy=#{policy_name}", "--name=#{assoc_name}",
      "--project=#{PROJECT}", "--global-firewall-policy")
  end
end

# Best-effort: any associations left after step 2 will block this delete;
# --quiet swallows the error and the next run will retry from foreman.log.
fwpolicies = extract_names("gcp_firewall_policy_created")
if section("Firewall policies", fwpolicies)
  fwpolicies.each do |policy|
    puts "Deleting firewall policy #{policy}"
    gcloud("compute", "network-firewall-policies", "delete", policy,
      "--project=#{PROJECT}", "--global")
  end
end

tag_values = extract_names("gcp_tag_value_created")
if section("Tag values", tag_values)
  tag_values.each do |tv|
    puts "Deleting tag value #{tv}"
    gcloud("resource-manager", "tags", "values", "delete", tv)
  end
end

tag_keys = extract_names("gcp_tag_key_created")
if section("Tag keys", tag_keys)
  tag_keys.each do |tk|
    puts "Deleting tag key #{tk}"
    gcloud("resource-manager", "tags", "keys", "delete", tk)
  end
end

ips = extract_names("gcp_static_ip_created")
if section("Static IPs", ips)
  ips.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed static IP entry: #{entry}" unless parts
    ip_name, region = parts
    puts "Releasing IP #{ip_name} in #{region}"
    gcloud("compute", "addresses", "delete", ip_name, "--region=#{region}", "--project=#{PROJECT}")
  end
end

subnets = extract_names("gcp_subnet_created")
if section("Subnets", subnets)
  subnets.each do |entry|
    parts = split_scoped(entry)
    next puts "  WARN: skipping malformed subnet entry: #{entry}" unless parts
    subnet_name, region = parts
    puts "Deleting subnet #{subnet_name} in #{region}"
    gcloud("compute", "networks", "subnets", "delete", subnet_name, "--region=#{region}", "--project=#{PROJECT}")
  end
end

vpcs = extract_names("gcp_vpc_created")
if section("VPC networks", vpcs)
  vpcs.each do |vpc|
    puts "Deleting VPC #{vpc}"
    gcloud("compute", "networks", "delete", vpc, "--project=#{PROJECT}")
  end
end

sas = extract_names("gcp_service_account_created")
if section("Service accounts", sas)
  sas.each do |sa|
    puts "Deleting SA #{sa}"
    gcloud("iam", "service-accounts", "delete", sa, "--project=#{PROJECT}")
  end
end

buckets = extract_names("gcp_gcs_bucket_created")
if section("GCS buckets", buckets)
  buckets.each do |bucket|
    puts "Deleting bucket gs://#{bucket}"
    gcloud("storage", "rm", "-r", "gs://#{bucket}", "--project=#{PROJECT}")
  end
end
