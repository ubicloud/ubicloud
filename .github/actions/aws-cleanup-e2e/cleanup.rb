#!/usr/bin/env ruby
# frozen_string_literal: true

# Tag-driven teardown of the AWS resources an e2e run creates.
#
# Clover tags every AWS resource it creates Ubicloud=<value> (Util.aws_tags in
# lib/util.rb) and this workflow sets that value to the GitHub run id, so the
# tag is a complete index of a run's resources.
#
# Two sweeps run per region: the current run (RUN_ID) unconditionally, then
# every other purely numeric Ubicloud value found in the region, but only for
# the ones the GitHub API confirms are completed runs of this very workflow.
# Both halves of that are load-bearing. Cancellation is imperative here -- the
# setup job cancels its siblings -- so a foreign run id is not by itself
# evidence that its owner is dead. And the account is shared, so a numeric tag
# is not by itself evidence that e2e wrote it.
#
# Nothing else is ever deleted: untagged resources, Ubicloud=true (production)
# and non-numeric values (developer sandboxes) are out of bounds. The one
# exception is the untagged children of a VPC we own, whose ownership the VPC's
# own tag establishes; untagged ENIs and instances inside such a VPC are
# reported and left alone.
#
# Postgres timelines leave an S3 bucket plus an IAM user and policy behind, and
# every non-runner AWS VM an IAM role, instance profile and cw-agent policy.
# Those are swept too, held to the very same gate: S3 per region, right after
# the EC2 sweeps, and IAM once globally at the end. Both discover by the
# Ubicloud tag and skip on the same run-id test, so production ("true") and
# developer resources stay out of reach. The tag is the sole delete authority;
# a bucket is additionally required to be named like a timeline ubid, and any
# other tagged bucket is reported rather than removed.
#
# Individual AWS failures are logged and stepped over, and every wait is
# capped. Whatever one run leaves behind the next run's stale sweep collects,
# so a partial sweep beats hitting the 20 minute job timeout mid-delete.
#
# Environment:
#   RUN_ID             GitHub run id to sweep, and the tag value to match
#   GITHUB_TOKEN       used to check stale runs; without it sweep 2 is skipped
#   GITHUB_REPOSITORY  defaults to ubicloud/ubicloud
#   DRY_RUN=1          report what would be deleted, delete nothing
#   CLEANUP_BUDGET_SEC overall budget, default 15 minutes
#   IAM_TAGGING=1      discover IAM through the tagging API instead of the
#                      default entity-by-entity listing. Faster, but this
#                      account's tagging API does not index IAM users or roles,
#                      so it silently misses them -- set only for an account
#                      whose tagging API is known to cover every IAM type.
# plus AWS credentials in the environment, and `aws` on PATH.

require "json"
require "net/http"
require "open3"
require "openssl"
require "uri"

module AwsCleanup
  # The regions e2e provisions AWS resources in. Sources of truth:
  # prog/test/github_runner.rb (eu-central-1, runner VMs),
  # prog/test/postgres_base.rb (us-west-2, Postgres tests) and
  # prog/test/ha_postgres_resource.rb (us-east-1, HA Postgres).
  REGIONS = %w[eu-central-1 us-east-1 us-west-2].freeze

  TAG_KEY = "Ubicloud"

  # Only tag values shaped like this can be run ids. Everything else is a
  # developer sandbox ($USER) or production ("true").
  RUN_TAG = /\A[0-9]+\z/

  # A tag value a sweep may be pointed at. EC2 filter values take `*` and
  # `?` as wildcards, which would silently widen a sweep to resources it
  # does not own, so only literals are accepted.
  LITERAL_TAG = /\A[^*?]+\z/

  DEFAULT_REPO = "ubicloud/ubicloud"
  DEFAULT_API_URL = "https://api.github.com"

  # The only workflow whose run ids may be swept. Its "Run tests" step is
  # what sets PROVIDER_RESOURCE_TAG_VALUE to the run id, so a tag naming
  # any other workflow was written by something else.
  WORKFLOW_PATH = ".github/workflows/e2e.yml"

  # Instance states that are not yet terminated. A terminated instance stays
  # visible to describe-instances for about an hour, and must not be waited
  # on or counted as live.
  LIVE_STATES = "pending,running,shutting-down,stopping,stopped"

  # aws ec2 describe-* subcommand => the JSON key holding its resource list,
  # for the tag scan. describe-instances is absent because it nests its
  # results under Reservations and needs a state filter.
  DESCRIBES = {
    "describe-vpc-endpoints" => "VpcEndpoints",
    "describe-network-interfaces" => "NetworkInterfaces",
    "describe-addresses" => "Addresses",
    "describe-security-groups" => "SecurityGroups",
    "describe-internet-gateways" => "InternetGateways",
    "describe-subnets" => "Subnets",
    "describe-route-tables" => "RouteTables",
    "describe-vpcs" => "Vpcs",
  }.freeze

  POLL_INTERVAL = 10
  INSTANCE_TERMINATE_CAP = 300
  ENDPOINT_DELETE_CAP = 300

  # Deletes are retried in dependency order rather than once each, because
  # AWS clears references asynchronously: an ENI stays "currently in use"
  # until its instance is gone, and security groups that reference each
  # other only become deletable one pass after their peer.
  DELETE_PASSES = 4
  DELETE_PASS_SLEEP = 20

  # A timeline names its bucket after its own ubid, so only a bucket named in
  # exactly that shape is one of ours; any other tagged bucket is an anomaly to
  # report rather than delete.
  BUCKET_NAME = /\Apt[0-9a-z]{24}\z/

  # A bucket is emptied a page (up to 1000 objects) at a time; the cap stops a
  # listing that never drains from spinning forever.
  BUCKET_EMPTY_PASSES = 1000

  # The region the global IAM tagging endpoint answers on.
  IAM_TAG_REGION = "us-east-1"

  # AWS error codes that mean the delete already happened: benign, not a
  # failure, for every S3 and IAM call.
  ALREADY_GONE = %w[NoSuchEntity NoSuchBucket].freeze

  # The IAM entity kinds the sweep deletes, in the order it must delete them --
  # a policy will not delete while attached and a role not while it sits in a
  # profile, so users, then roles, then profiles, then policies, each kind
  # clearing the references the next one waits on. Per kind: the tagging API
  # filter that finds it; the list call, response key and extra args that
  # enumerate it when that API is denied; the field naming an entity and the
  # tag call (with its flag) that reads the entity's tags on that fallback; and
  # the name shape a reviewer should expect, nil where there is none (a VM role
  # is named for its VM, with no fixed shape).
  IAM_KINDS = {
    user: {
      filter: "iam:user", list_cmd: "list-users", list_key: "Users", list_args: [].freeze,
      id: "UserName", tags: "list-user-tags", flag: "--user-name", name: /\Apt[0-9a-z]{24}\z/,
    },
    role: {
      filter: "iam:role", list_cmd: "list-roles", list_key: "Roles", list_args: [].freeze,
      id: "RoleName", tags: "list-role-tags", flag: "--role-name", name: nil,
    },
    instance_profile: {
      filter: "iam:instance-profile", list_cmd: "list-instance-profiles", list_key: "InstanceProfiles", list_args: [].freeze,
      id: "InstanceProfileName", tags: "list-instance-profile-tags", flag: "--instance-profile-name", name: /-instance-profile\z/,
    },
    policy: {
      filter: "iam:policy", list_cmd: "list-policies", list_key: "Policies", list_args: %w[--scope Local].freeze,
      id: "Arn", tags: "list-policy-tags", flag: "--policy-arn", name: /\Apt[0-9a-z]{24}\z|-cw-agent-policy\z/,
    },
  }.freeze

  def self.now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.tag_value(resource, key = TAG_KEY)
    resource["Tags"]&.find { |tag| tag["Key"] == key }&.[]("Value")
  end

  def self.resource_name(resource)
    tag_value(resource, "Name") || "unnamed"
  end

  def self.expired?(deadline)
    deadline && now >= deadline
  end

  def self.env(key, default)
    value = ENV[key].to_s
    value.empty? ? default : value
  end

  # The single seam every `aws` invocation passes through, so that callers
  # can substitute a stub and DRY_RUN can suppress every mutation in one
  # place.
  class Cli
    attr_reader :dry_run

    def initialize(dry_run: false)
      @dry_run = dry_run
    end

    def capture(args)
      Open3.capture3("aws", *args)
    end

    def caller_identity
      json(["sts", "get-caller-identity"]).first
    end

    # Read-only call. Returns the parsed body, or nil if the call failed;
    # callers treat nil as "found nothing" and carry on.
    def describe(region, *args)
      body, error = json(["ec2", *args, "--region", region])
      puts "  WARN: aws ec2 #{args.first} in #{region} failed: #{Cli.brief(error)}" unless body
      body
    end

    # Mutating call. Returns :ok, :gone (already deleted, which is success)
    # or :failed.
    def mutate(region, *args)
      return :ok if dry_run
      body, error = json(["ec2", *args, "--region", region])
      unless body
        return :gone if /NotFound|does not exist/i.match?(error)
        puts "  WARN: aws ec2 #{args.first} in #{region} failed: #{Cli.brief(error)}"
        return :failed
      end
      # Batch deletes such as delete-vpc-endpoints report per-resource
      # failures in the body and still exit zero.
      rejected = body["Unsuccessful"]
      return :ok if rejected.nil? || rejected.empty?
      puts "  WARN: aws ec2 #{args.first} in #{region} rejected: #{rejected.map { |r| r.dig("Error", "Message") }.join("; ")}"
      :failed
    end

    # A read-only call to any aws service, for the S3 and IAM sweeps that the
    # ec2-only `describe` above cannot serve. The full argument vector is
    # passed through. Returns [parsed body, error message], exactly one nil.
    # Unlike `describe` it does not warn on failure, because for these sweeps
    # some errors are control flow -- an AccessDenied that selects a fallback,
    # a NoSuchEntity that means "already gone" -- rather than warnings.
    def get(*args)
      json(args)
    end

    # A mutating call to any aws service. Returns nil on success, and under a
    # dry run without calling aws at all; otherwise the AWS error code
    # ("NoSuchEntity", "BucketNotEmpty", ...), so the caller can tell a benign
    # already-done from a real failure.
    def delete(*args)
      return if dry_run
      _body, error = json(args)
      return unless error
      Cli.error_code(error)
    end

    def self.brief(error)
      error.to_s.lines.map(&:strip).reject(&:empty?).last || "no error output"
    end

    # The code AWS parenthesizes in a CLI error, e.g. "NoSuchEntity" out of
    # "An error occurred (NoSuchEntity) when calling ...", or "Unknown".
    def self.error_code(error)
      error.to_s[/An error occurred \(([^)]+)\)/, 1] || "Unknown"
    end

    private

    # Returns [parsed body, nil] on success and [nil, message] on failure.
    def json(args)
      stdout, stderr, status = capture(args + ["--output", "json"])
      return [nil, stderr] unless status.success?
      # A few subcommands (terminate-instances aside) print nothing at all.
      [stdout.strip.empty? ? {} : JSON.parse(stdout), nil]
    rescue JSON::ParserError => e
      [nil, "unparsable JSON response: #{e.message}"]
    end
  end

  # Read-only lookups shared by the sweep and the stale-run scan. Includers
  # provide a `cli`.
  module Describe
    def describe(region, command, key, *filters)
      body = cli.describe(region, command, "--filters", *filters)
      body ? body.fetch(key, []) : []
    end

    def instances(region, *filters)
      body = cli.describe(region, "describe-instances", "--filters", *filters, "Name=instance-state-name,Values=#{LIVE_STATES}")
      body ? body.fetch("Reservations", []).flat_map { |reservation| reservation.fetch("Instances", []) } : []
    end
  end

  # One unit of work: everything tagged with a single value in a single
  # region, deleted in dependency order.
  class Sweep
    include Describe

    # The id field of each resource kind, used both to deduplicate the
    # inventory and to keep its listing order stable.
    ID_KEYS = {
      instances: "InstanceId",
      vpc_endpoints: "VpcEndpointId",
      enis: "NetworkInterfaceId",
      eips: "AllocationId",
      security_groups: "GroupId",
      internet_gateways: "InternetGatewayId",
      subnets: "SubnetId",
      route_tables: "RouteTableId",
      vpcs: "VpcId",
    }.freeze

    attr_reader :cli, :deleted, :failed, :skipped

    def initialize(cli:, region:, tag_value:, deadline: nil)
      # `*` and `?` are wildcards in an EC2 filter value, so a tag value
      # carrying either would match, and delete, resources it does not own.
      raise ArgumentError, "#{tag_value.inspect} is not a literal tag value" unless LITERAL_TAG.match?(tag_value)
      @cli = cli
      @region = region
      @tag_value = tag_value
      @deadline = deadline
      @deleted = 0
      @failed = 0
      @skipped = 0
      @occupied_vpcs = []
    end

    def run
      puts "#{@region}: sweeping #{TAG_KEY}=#{@tag_value}"
      if inventory.values.all?(&:empty?)
        puts "  nothing tagged #{TAG_KEY}=#{@tag_value}"
        return self
      end
      report_foreign_tenants
      terminate_instances
      delete_vpc_endpoints
      drain(delete_jobs)
      self
    end

    private

    def inventory
      @inventory ||= begin
        found = tagged_inventory
        merge_vpc_children(found) unless found[:vpcs].empty?
        found.each { |kind, list| list.sort_by! { |resource| resource[ID_KEYS[kind]].to_s } }
        found
      end
    end

    def tagged_inventory
      tag = "Name=tag:#{TAG_KEY},Values=#{@tag_value}"
      {
        instances: instances(@region, tag),
        vpc_endpoints: describe(@region, "describe-vpc-endpoints", "VpcEndpoints", tag),
        enis: describe(@region, "describe-network-interfaces", "NetworkInterfaces", tag),
        eips: describe(@region, "describe-addresses", "Addresses", tag),
        security_groups: deletable_security_groups(tag),
        internet_gateways: describe(@region, "describe-internet-gateways", "InternetGateways", tag),
        subnets: describe(@region, "describe-subnets", "Subnets", tag),
        route_tables: deletable_route_tables(tag),
        vpcs: describe(@region, "describe-vpcs", "Vpcs", tag).reject { |vpc| vpc["IsDefault"] },
      }
    end

    # A VPC's own tag establishes ownership of everything inside it, so its
    # children may be deleted whether or not they carry the tag themselves.
    # ENIs and instances are deliberately excluded: see report_foreign_tenants.
    #
    # An EC2 filter accepts a list of values, so one lookup covers every VPC
    # the run owns. Asking per VPC instead dominates the cost of a sweep,
    # which is charged against the job's 20 minute timeout.
    def merge_vpc_children(found)
      ids = found[:vpcs].map { |vpc| vpc["VpcId"] }.join(",")
      vpc = "Name=vpc-id,Values=#{ids}"
      merge(found, :vpc_endpoints, describe(@region, "describe-vpc-endpoints", "VpcEndpoints", vpc))
      merge(found, :security_groups, deletable_security_groups(vpc))
      merge(found, :internet_gateways, describe(@region, "describe-internet-gateways", "InternetGateways", "Name=attachment.vpc-id,Values=#{ids}"))
      merge(found, :subnets, describe(@region, "describe-subnets", "Subnets", vpc))
      merge(found, :route_tables, deletable_route_tables(vpc))
    end

    def merge(found, kind, candidates)
      id_key = ID_KEYS[kind]
      known = found[kind].map { |resource| resource[id_key] }
      candidates.each do |resource|
        next if known.include?(resource[id_key])
        owner = AwsCleanup.tag_value(resource)
        if owner && owner != @tag_value
          puts "  SKIP #{resource[id_key]}: sits in an owned VPC but is tagged #{TAG_KEY}=#{owner}"
          @skipped += 1
          next
        end
        found[kind] << resource
      end
    end

    # The default security group and the main route table cannot be deleted
    # and disappear with their VPC.
    def deletable_security_groups(*filters)
      describe(@region, "describe-security-groups", "SecurityGroups", *filters).reject { |group| group["GroupName"] == "default" }
    end

    def deletable_route_tables(*filters)
      describe(@region, "describe-route-tables", "RouteTables", *filters).reject do |table|
        table.fetch("Associations", []).any? { |association| association["Main"] }
      end
    end

    # Instances and ENIs inside an owned VPC that the tag does not cover are
    # somebody else's: a hand-launched debug host, most often. Deleting them
    # is not ours to decide, so they are named here and the VPC is left to
    # fail its delete if they hold it.
    def report_foreign_tenants
      return if inventory[:vpcs].empty?
      owned_instances = inventory[:instances].map { |instance| instance["InstanceId"] }
      owned_enis = inventory[:enis].map { |eni| eni["NetworkInterfaceId"] }
      filter = "Name=vpc-id,Values=#{inventory[:vpcs].map { |vpc| vpc["VpcId"] }.join(",")}"
      foreign_instances = instances(@region, filter).reject { |instance| owned_instances.include?(instance["InstanceId"]) }
      # AWS-managed interfaces (endpoint, NAT, ...) go away with the resource
      # that requested them, and an instance's primary interface goes away
      # with the instance, so neither is a foreign tenant.
      foreign_enis = describe(@region, "describe-network-interfaces", "NetworkInterfaces", filter).reject do |eni|
        owned_enis.include?(eni["NetworkInterfaceId"]) ||
          eni["InterfaceType"] != "interface" ||
          owned_instances.include?(eni.dig("Attachment", "InstanceId")) ||
          foreign_instances.any? { |instance| instance["InstanceId"] == eni.dig("Attachment", "InstanceId") }
      end
      inventory[:vpcs].each do |vpc|
        vpc_id = vpc["VpcId"]
        here_instances = foreign_instances.select { |instance| instance["VpcId"] == vpc_id }
        here_enis = foreign_enis.select { |eni| eni["VpcId"] == vpc_id }
        next if here_instances.empty? && here_enis.empty?
        puts "  NOT MINE in #{vpc_id} (#{AwsCleanup.resource_name(vpc)}), left in place; the VPC delete will fail while they exist:"
        here_instances.each do |instance|
          puts "    instance #{instance["InstanceId"]} #{AwsCleanup.resource_name(instance)} launched #{instance["LaunchTime"]} key #{instance["KeyName"].inspect}"
        end
        here_enis.each { |eni| puts "    interface #{eni["NetworkInterfaceId"]} #{eni["Description"].inspect}" }
        @skipped += here_instances.size + here_enis.size
        @occupied_vpcs << vpc_id
      end
    end

    # Both of these delete one resource per call rather than in a batch, so
    # that one rejected id -- an endpoint AWS is already deleting, an
    # instance that raced us -- neither hides the others' outcome nor robs
    # them of the wait that follows.
    def terminate_instances
      terminating = inventory[:instances].filter_map do |instance|
        id = instance["InstanceId"]
        announce("Terminate instance #{id} (#{AwsCleanup.resource_name(instance)})")
        if cli.mutate(@region, "terminate-instances", "--instance-ids", id) == :failed
          @failed += 1
          next
        end
        @deleted += 1
        id
      end
      return if terminating.empty? || cli.dry_run
      wait_until("instances to terminate", INSTANCE_TERMINATE_CAP) { instances_terminated?(terminating) }
    end

    def delete_vpc_endpoints
      deleting = inventory[:vpc_endpoints].filter_map do |endpoint|
        id = endpoint["VpcEndpointId"]
        announce("Delete VPC endpoint #{id} (#{AwsCleanup.resource_name(endpoint)})")
        if cli.mutate(@region, "delete-vpc-endpoints", "--vpc-endpoint-ids", id) == :failed
          @failed += 1
          next
        end
        @deleted += 1
        id
      end
      return if deleting.empty? || cli.dry_run
      # An endpoint's interfaces outlive the delete call by minutes and pin
      # the security groups and the VPC until they are gone.
      wait_until("VPC endpoints to disappear", ENDPOINT_DELETE_CAP) { endpoints_gone?(deleting) }
    end

    # These two ask the AWS CLI directly rather than going through
    # Describe, which cannot tell an empty answer from a failed call. That
    # conflation is harmless while building an inventory -- a lookup that
    # failed contributes nothing to delete -- but here it would read as
    # "already gone", cut the wait short, and start deleting resources the
    # instance or the endpoint still pins.
    def instances_terminated?(ids)
      body = cli.describe(@region, "describe-instances", "--filters", "Name=instance-id,Values=#{ids.join(",")}", "Name=instance-state-name,Values=#{LIVE_STATES}")
      body&.fetch("Reservations", [])&.empty?
    end

    def endpoints_gone?(ids)
      body = cli.describe(@region, "describe-vpc-endpoints", "--filters", "Name=vpc-endpoint-id,Values=#{ids.join(",")}")
      body&.fetch("VpcEndpoints", [])&.all? { |endpoint| endpoint["State"] == "deleted" }
    end

    # A VPC someone else is sitting in. Its resources are still worth one
    # attempt, since a tenant only blocks what it actually holds, but not a
    # second: the tenant is a standing condition that a retry cannot clear,
    # and report_foreign_tenants has already named it.
    def occupied?(vpc_id)
      @occupied_vpcs.include?(vpc_id)
    end

    # Everything left, in the order AWS requires: interfaces and addresses
    # detach from instances, security groups and gateways from the VPC, then
    # its subnets and route tables, then the VPC itself.
    def delete_jobs
      jobs = []
      inventory[:enis].each do |eni|
        id = eni["NetworkInterfaceId"]
        jobs << {desc: "Delete interface #{id} (#{AwsCleanup.resource_name(eni)})", run: -> { cli.mutate(@region, "delete-network-interface", "--network-interface-id", id) }}
      end
      inventory[:eips].each do |eip|
        allocation = eip["AllocationId"]
        association = eip["AssociationId"]
        jobs << {desc: "Release address #{allocation} #{eip["PublicIp"]}#{" (disassociating first)" if association}", run: lambda do
          cli.mutate(@region, "disassociate-address", "--association-id", association) if association
          cli.mutate(@region, "release-address", "--allocation-id", allocation)
        end}
      end
      inventory[:security_groups].each do |group|
        id = group["GroupId"]
        jobs << {desc: "Delete security group #{id} (#{group["GroupName"]})", once: occupied?(group["VpcId"]), run: -> { cli.mutate(@region, "delete-security-group", "--group-id", id) }}
      end
      inventory[:internet_gateways].each do |gateway|
        id = gateway["InternetGatewayId"]
        attached = gateway.fetch("Attachments", []).filter_map { |attachment| attachment["VpcId"] }
        jobs << {desc: "Delete internet gateway #{id} (#{AwsCleanup.resource_name(gateway)})#{" detaching from #{attached.join(", ")}" unless attached.empty?}", once: attached.any? { |vpc_id| occupied?(vpc_id) }, run: lambda do
          attached.each { |vpc_id| cli.mutate(@region, "detach-internet-gateway", "--internet-gateway-id", id, "--vpc-id", vpc_id) }
          cli.mutate(@region, "delete-internet-gateway", "--internet-gateway-id", id)
        end}
      end
      inventory[:subnets].each do |subnet|
        id = subnet["SubnetId"]
        jobs << {desc: "Delete subnet #{id} (#{AwsCleanup.resource_name(subnet)})", once: occupied?(subnet["VpcId"]), run: -> { cli.mutate(@region, "delete-subnet", "--subnet-id", id) }}
      end
      inventory[:route_tables].each do |table|
        id = table["RouteTableId"]
        jobs << {desc: "Delete route table #{id} (#{AwsCleanup.resource_name(table)})", once: occupied?(table["VpcId"]), run: -> { cli.mutate(@region, "delete-route-table", "--route-table-id", id) }}
      end
      inventory[:vpcs].each do |vpc|
        id = vpc["VpcId"]
        jobs << {desc: "Delete VPC #{id} (#{AwsCleanup.resource_name(vpc)})", once: occupied?(id), run: -> { cli.mutate(@region, "delete-vpc", "--vpc-id", id) }, on_leak: -> { report_vpc_dependencies(id) }}
      end
      jobs
    end

    def drain(jobs)
      pending = jobs
      blocked = []
      passes = cli.dry_run ? 1 : DELETE_PASSES
      remaining = passes
      while remaining.positive?
        retryable = []
        deferred = nil
        pending.each_with_index do |job, index|
          if out_of_time?
            # Everything this pass has already failed is still owed a
            # retry, so it is deferred alongside the untried tail.
            deferred = retryable + pending[index..]
            break
          end
          announce(job[:desc])
          if job[:run].call != :failed
            @deleted += 1
          elsif job[:once]
            blocked << job
          else
            retryable << job
          end
        end
        if deferred
          @failed += deferred.size
          report("budget spent; deferring #{deferred.size} delete(s) to the next run's stale sweep", deferred)
          break
        end
        pending = retryable
        break if pending.empty?
        remaining -= 1
        sleep DELETE_PASS_SLEEP if remaining.positive?
      end
      unless deferred
        @failed += pending.size
        report("LEAKED: #{pending.size} resource(s) survived #{passes} delete passes", pending, on_leak: true) unless pending.empty?
      end
      @failed += blocked.size
      report("BLOCKED: #{blocked.size} resource(s) held by the tenants reported above, not retried", blocked) unless blocked.empty?
    end

    def report(headline, jobs, on_leak: false)
      puts "  #{headline}:"
      jobs.each do |job|
        puts "    #{job[:desc]}"
        job[:on_leak]&.call if on_leak
      end
    end

    # A VPC only refuses to die because something still holds an address in
    # it, and describe-network-interfaces is the one call that names it.
    def report_vpc_dependencies(vpc_id)
      describe(@region, "describe-network-interfaces", "NetworkInterfaces", "Name=vpc-id,Values=#{vpc_id}").each do |eni|
        puts "      held by interface #{eni["NetworkInterfaceId"]} #{eni["Description"].inspect} status #{eni["Status"]}"
      end
    end

    def announce(description)
      puts(cli.dry_run ? "  [dry-run] #{description}" : "  #{description}")
    end

    def out_of_time?
      AwsCleanup.expired?(@deadline)
    end

    def wait_until(label, cap)
      limit = AwsCleanup.now + cap
      until yield
        if AwsCleanup.now >= limit || out_of_time?
          puts "  gave up waiting for #{label}; continuing"
          return false
        end
        sleep POLL_INTERVAL
      end
      true
    end
  end

  # Discovery by the Ubicloud tag through the Resource Groups Tagging API,
  # shared by the S3 and IAM sweeps. Both find their resources this way and
  # then defer every delete to the run-id gate, so neither can reach anything
  # the EC2 sweep would spare. Includers provide a `cli`.
  module TagQuery
    # [arn, tag value] for every Ubicloud-tagged resource of `type` in
    # `region`, following pagination, or nil if the tagging API itself could
    # not be reached -- which the caller treats as "ask another way", not
    # "nothing tagged". The filter is on the key alone, so the value the caller
    # gates on is whatever the resource actually carries.
    def tagged(region, type)
      pairs = []
      token = nil
      loop do
        args = ["resourcegroupstaggingapi", "get-resources", "--region", region, "--tag-filters", "Key=#{TAG_KEY}", "--resource-type-filters", type]
        args.push("--pagination-token", token) unless token.to_s.empty?
        body, error = cli.get(*args)
        unless body
          puts "  WARN: tagging API get-resources #{type} in #{region} unavailable: #{Cli.brief(error)}"
          return nil
        end
        body.fetch("ResourceTagMappingList", []).each do |resource|
          pairs << [resource["ResourceARN"], AwsCleanup.tag_value("Tags" => resource["Tags"])]
        end
        token = body["PaginationToken"]
        break if token.to_s.empty?
      end
      pairs
    end
  end

  # The S3 half of a sweep: every Ubicloud-tagged bucket in one region whose
  # tag value the gate clears, emptied then deleted. A tagged bucket whose name
  # is not a timeline ubid is reported and left in place whatever its tag,
  # since the only writer of these buckets names them after the timeline.
  class BucketSweep
    include TagQuery

    attr_reader :cli, :deleted, :failed, :skipped

    def initialize(cli:, region:, permit:, deadline: nil)
      @cli = cli
      @region = region
      @permit = permit
      @deadline = deadline
      @deleted = 0
      @failed = 0
      @skipped = 0
    end

    def run
      buckets = discover
      return self if buckets.nil? || buckets.empty?
      puts "#{@region}: #{buckets.size} Ubicloud-tagged bucket(s)"
      buckets.sort_by { |name, _tag| name }.each do |name, tag|
        break if AwsCleanup.expired?(@deadline)
        sweep_bucket(name, tag)
      end
      self
    end

    private

    # [name, tag] for each tagged bucket, via the tagging API, or a
    # list-buckets + get-bucket-tagging scan of this region if that API is
    # denied. nil (only the tagging API returns it) means fall back; an empty
    # list means nothing is tagged and there is nothing to fall back to.
    def discover
      pairs = tagged(@region, "s3")
      pairs &&= pairs.map { |arn, tag| [arn.split(":::").last, tag] }
      pairs || discover_by_listing
    end

    # list-buckets is global, so each bucket's region is confirmed before it is
    # claimed for this region's sweep; without that every region would try to
    # delete every bucket.
    def discover_by_listing
      body, error = cli.get("s3api", "list-buckets")
      unless body
        puts "  WARN: s3api list-buckets failed: #{Cli.brief(error)}"
        return nil
      end
      body.fetch("Buckets", []).filter_map do |bucket|
        name = bucket["Name"]
        tag = bucket_tag(name)
        [name, tag] if tag && bucket_region(name) == @region
      end
    end

    # The bucket's Ubicloud tag value, or nil if it has none (get-bucket-tagging
    # raises NoSuchTagSet on an untagged bucket) or the call was denied.
    def bucket_tag(name)
      body, = cli.get("s3api", "get-bucket-tagging", "--bucket", name, "--region", @region)
      AwsCleanup.tag_value("Tags" => body["TagSet"]) if body
    end

    # us-east-1 reports its buckets with a null LocationConstraint.
    def bucket_region(name)
      body, = cli.get("s3api", "get-bucket-location", "--bucket", name, "--region", IAM_TAG_REGION)
      constraint = body && body["LocationConstraint"]
      constraint.to_s.empty? ? "us-east-1" : constraint
    end

    def sweep_bucket(name, tag)
      unless BUCKET_NAME.match?(name)
        puts "  REPORT bucket #{name} (#{TAG_KEY}=#{tag}): not a timeline bucket name, left in place"
        @skipped += 1
        return
      end
      if (refusal = @permit.call(tag))
        puts "  SKIP bucket #{name}: #{refusal}"
        @skipped += 1
        return
      end
      announce("Delete bucket #{name} (#{TAG_KEY}=#{tag})")
      if empty_and_delete(name)
        @deleted += 1
      else
        @failed += 1
      end
    end

    # Empty the bucket then remove it. Created unversioned, it empties with
    # list-objects-v2; only if a delete-bucket still reports BucketNotEmpty do
    # we pay for the versioned listing, which also sweeps delete markers.
    # NoSuchBucket at any point means the bucket is already gone: success.
    def empty_and_delete(name)
      return true if cli.dry_run
      empty(name, "list-objects-v2", "Contents")
      code = cli.delete("s3api", "delete-bucket", "--bucket", name, "--region", @region)
      if code == "BucketNotEmpty"
        empty(name, "list-object-versions", "Versions", "DeleteMarkers")
        code = cli.delete("s3api", "delete-bucket", "--bucket", name, "--region", @region)
      end
      return true if code.nil? || code == "NoSuchBucket"
      puts "  WARN: delete-bucket #{name} failed: #{code}"
      false
    end

    # Delete everything the listing command returns, a page (up to 1000) at a
    # time, until it comes back empty. `keys` are the response members holding
    # deletable entries: the objects, and for the versioned listing the delete
    # markers too. Each entry carries a VersionId only in the versioned case,
    # where it must be passed to delete the right generation.
    def empty(name, command, *keys)
      BUCKET_EMPTY_PASSES.times do
        body, error = cli.get("s3api", command, "--bucket", name, "--region", @region)
        unless body
          puts "  WARN: #{command} #{name} failed: #{Cli.brief(error)}" unless ALREADY_GONE.include?(Cli.error_code(error))
          return
        end
        entries = keys.flat_map { |key| body.fetch(key, []) }
        return if entries.empty?
        entries.each_slice(1000) do |slice|
          payload = JSON.dump("Objects" => slice.map { |entry| entry.slice("Key", "VersionId") }, "Quiet" => true)
          code = cli.delete("s3api", "delete-objects", "--bucket", name, "--region", @region, "--delete", payload)
          puts "  WARN: delete-objects #{name} failed: #{code}" if code && !ALREADY_GONE.include?(code)
        end
      end
    end

    def announce(description)
      puts(cli.dry_run ? "  [dry-run] #{description}" : "  #{description}")
    end
  end

  # The IAM half of a sweep, run once globally: every Ubicloud-tagged user,
  # role, instance profile and policy whose tag value the gate clears, deleted
  # in that order. A name is reported for a human to eyeball but never decides
  # anything; only the tag and the run-id gate do.
  class IamSweep
    include TagQuery

    attr_reader :cli, :deleted, :failed, :skipped

    def initialize(cli:, permit:, deadline: nil, via_listing: true)
      @cli = cli
      @permit = permit
      @deadline = deadline
      @via_listing = via_listing
      @deleted = 0
      @failed = 0
      @skipped = 0
    end

    def run
      IAM_KINDS.each_key do |kind|
        break if AwsCleanup.expired?(@deadline)
        sweep_kind(kind)
      end
      self
    end

    private

    def sweep_kind(kind)
      entities = discover(kind)
      return if entities.nil? || entities.empty?
      puts "IAM: #{entities.size} Ubicloud-tagged #{label(kind)}(s)"
      entities.sort_by { |name, _arn, _tag| name }.each do |name, arn, tag|
        break if AwsCleanup.expired?(@deadline)
        act(kind, name, arn, tag)
      end
    end

    # [name, arn, tag] for each tagged entity of `kind`. By default this is a
    # list + per-entity tag scan, because the tagging API does not index users
    # or roles in this account and would silently miss them; IAM_TAGGING opts
    # back into the tagging API where it is known to be complete. The name is
    # the ARN's last segment, which is what every delete call below takes (only
    # the policy delete needs the ARN itself).
    def discover(kind)
      meta = IAM_KINDS.fetch(kind)
      pairs = @via_listing ? discover_by_listing(kind) : (tagged(IAM_TAG_REGION, meta[:filter]) || discover_by_listing(kind))
      pairs&.map { |arn, tag| [arn.split("/").last, arn, tag] }
    end

    # Enumerate the kind and read each entity's tags one call at a time. Slow
    # -- it walks every entity in the account, not just ours -- but the only
    # way to see IAM users and roles here; it is the default, and also the
    # fallback the tagging path drops to when denied.
    def discover_by_listing(kind)
      meta = IAM_KINDS.fetch(kind)
      iam_list(meta[:list_cmd], meta[:list_key], *meta[:list_args]).filter_map do |entity|
        arn = entity["Arn"]
        identifier = (meta[:id] == "Arn") ? arn : entity[meta[:id]]
        tag = AwsCleanup.tag_value("Tags" => iam_list(meta[:tags], "Tags", meta[:flag], identifier))
        [arn, tag] if tag
      end
    end

    def act(kind, name, arn, tag)
      note = name_note(kind, name)
      if (refusal = @permit.call(tag))
        puts "  SKIP #{label(kind)} #{name}#{note}: #{refusal}"
        @skipped += 1
        return
      end
      announce("Delete #{label(kind)} #{name} (#{TAG_KEY}=#{tag})#{note}")
      if cli.dry_run
        @deleted += 1
      elsif delete_entity(kind, name, arn)
        @deleted += 1
      else
        @failed += 1
      end
    end

    # A parenthetical flag for a name that is not the shape its kind usually
    # takes, drawing a reviewer's eye -- never itself a reason to keep or drop.
    def name_note(kind, name)
      shape = IAM_KINDS.fetch(kind)[:name]
      (shape && !shape.match?(name)) ? " [name unexpected for a #{label(kind)}]" : ""
    end

    def label(kind)
      kind.to_s.tr("_", " ")
    end

    def delete_entity(kind, name, arn)
      case kind
      when :user then delete_user(name)
      when :role then delete_role(name)
      when :instance_profile then delete_instance_profile(name)
      when :policy then delete_policy(arn)
      end
    end

    def delete_user(name)
      iam_list("list-access-keys", "AccessKeyMetadata", "--user-name", name).each do |key|
        tolerate cli.delete("iam", "delete-access-key", "--user-name", name, "--access-key-id", key["AccessKeyId"]), "delete-access-key #{name}"
      end
      iam_list("list-attached-user-policies", "AttachedPolicies", "--user-name", name).each do |policy|
        tolerate cli.delete("iam", "detach-user-policy", "--user-name", name, "--policy-arn", policy["PolicyArn"]), "detach-user-policy #{name}"
      end
      finalize cli.delete("iam", "delete-user", "--user-name", name), "delete-user #{name}"
    end

    def delete_role(name)
      iam_list("list-instance-profiles-for-role", "InstanceProfiles", "--role-name", name).each do |profile|
        tolerate cli.delete("iam", "remove-role-from-instance-profile", "--instance-profile-name", profile["InstanceProfileName"], "--role-name", name), "remove-role-from-instance-profile #{name}"
      end
      iam_list("list-attached-role-policies", "AttachedPolicies", "--role-name", name).each do |policy|
        tolerate cli.delete("iam", "detach-role-policy", "--role-name", name, "--policy-arn", policy["PolicyArn"]), "detach-role-policy #{name}"
      end
      iam_list("list-role-policies", "PolicyNames", "--role-name", name).each do |inline|
        tolerate cli.delete("iam", "delete-role-policy", "--role-name", name, "--policy-name", inline), "delete-role-policy #{name}"
      end
      finalize cli.delete("iam", "delete-role", "--role-name", name), "delete-role #{name}"
    end

    def delete_instance_profile(name)
      body, = cli.get("iam", "get-instance-profile", "--instance-profile-name", name)
      (body ? body.dig("InstanceProfile", "Roles") || [] : []).each do |role|
        tolerate cli.delete("iam", "remove-role-from-instance-profile", "--instance-profile-name", name, "--role-name", role["RoleName"]), "remove-role-from-instance-profile #{name}"
      end
      finalize cli.delete("iam", "delete-instance-profile", "--instance-profile-name", name), "delete-instance-profile #{name}"
    end

    def delete_policy(arn)
      detach_policy(arn)
      iam_list("list-policy-versions", "Versions", "--policy-arn", arn).each do |version|
        next if version["IsDefaultVersion"]
        tolerate cli.delete("iam", "delete-policy-version", "--policy-arn", arn, "--version-id", version["VersionId"]), "delete-policy-version #{arn}"
      end
      finalize cli.delete("iam", "delete-policy", "--policy-arn", arn), "delete-policy #{arn}"
    end

    # Detach the policy from every user, role and group still holding it, so
    # the delete below is unblocked. In iam-access mode a timeline policy is
    # attached to server roles rather than a user, so all three are checked.
    def detach_policy(arn)
      body, error = cli.get("iam", "list-entities-for-policy", "--policy-arn", arn)
      unless body
        puts "  WARN: iam list-entities-for-policy #{arn} failed: #{Cli.brief(error)}" unless ALREADY_GONE.include?(Cli.error_code(error))
        return
      end
      body.fetch("PolicyUsers", []).each { |user| tolerate cli.delete("iam", "detach-user-policy", "--user-name", user["UserName"], "--policy-arn", arn), "detach-user-policy #{user["UserName"]}" }
      body.fetch("PolicyRoles", []).each { |role| tolerate cli.delete("iam", "detach-role-policy", "--role-name", role["RoleName"], "--policy-arn", arn), "detach-role-policy #{role["RoleName"]}" }
      body.fetch("PolicyGroups", []).each { |group| tolerate cli.delete("iam", "detach-group-policy", "--group-name", group["GroupName"], "--policy-arn", arn), "detach-group-policy #{group["GroupName"]}" }
    end

    # An iam list call, following pagination markers, returning the array at
    # `key` across every page, or [] on NoSuchEntity or any failure -- a
    # sub-listing we cannot read mid-delete is one we can treat as empty.
    def iam_list(command, key, *args)
      items = []
      marker = nil
      loop do
        call = ["iam", command, *args]
        call.push("--marker", marker) if marker
        body, error = cli.get(*call)
        unless body
          puts "  WARN: iam #{command} failed: #{Cli.brief(error)}" unless ALREADY_GONE.include?(Cli.error_code(error))
          break
        end
        items.concat(body.fetch(key, []))
        marker = body["Marker"]
        break unless body["IsTruncated"] && marker
      end
      items
    end

    def tolerate(code, what)
      puts "  WARN: #{what} failed: #{code}" unless code.nil? || ALREADY_GONE.include?(code)
    end

    def finalize(code, what)
      return true if code.nil? || ALREADY_GONE.include?(code)
      puts "  WARN: #{what} failed: #{code}"
      false
    end

    def announce(description)
      puts(cli.dry_run ? "  [dry-run] #{description}" : "  #{description}")
    end
  end

  # Drives both sweeps across every region and decides which stale run ids
  # are safe to touch.
  class Runner
    include Describe

    attr_reader :cli

    def initialize(cli:, run_id:, token:, repo: DEFAULT_REPO, api_url: DEFAULT_API_URL, deadline: nil, iam_via_listing: true)
      @cli = cli
      @run_id = run_id
      @token = token
      @repo = repo
      @api_url = api_url
      @deadline = deadline
      @iam_via_listing = iam_via_listing
      @refusals = {}
      @deleted = 0
      @failed = 0
      @skipped = 0
    end

    def run
      REGIONS.each { |region| sweep(region, @run_id) }
      if @token.to_s.empty?
        puts "GITHUB_TOKEN is unset; skipping the stale sweep rather than deleting on an unverified run id"
      else
        REGIONS.each { |region| stale_sweep(region) }
      end
      # S3 and IAM gate every value themselves, current run included, so they
      # run whether or not the token let the stale EC2 sweep proceed: without
      # it only the current run's own buckets and entities pass the gate.
      REGIONS.each { |region| bucket_sweep(region) }
      iam_sweep
      puts "Summary: #{cli.dry_run ? "would delete" : "deleted"} #{@deleted}, skipped #{@skipped}, failed #{@failed}"
    end

    private

    def bucket_sweep(region)
      if AwsCleanup.expired?(@deadline)
        puts "#{region}: budget spent; leaving its tagged buckets to the next run"
        return
      end
      tally BucketSweep.new(cli:, region:, permit: method(:refusal_for), deadline: @deadline).run
    end

    def iam_sweep
      if AwsCleanup.expired?(@deadline)
        puts "budget spent; leaving tagged IAM entities to the next run"
        return
      end
      tally IamSweep.new(cli:, permit: method(:refusal_for), deadline: @deadline, via_listing: @iam_via_listing).run
    end

    def tally(sweep)
      @deleted += sweep.deleted
      @failed += sweep.failed
      @skipped += sweep.skipped
    end

    # Whether a tag value's S3 or IAM resources may be deleted, as a reason
    # string to skip or nil to permit. The current run is always ours; a
    # numeric run id is touchable only once the GitHub API vouches it a
    # completed run of this workflow (the same test the stale EC2 sweep
    # applies, memoized alongside it); production's "true" and a developer's
    # name never are.
    def refusal_for(value)
      return if value == @run_id
      return "#{value.inspect} is not a run id" unless RUN_TAG.match?(value)
      return "no GITHUB_TOKEN to verify the run" if @token.to_s.empty?
      refusal_to_sweep(value)
    end

    # Enumerating a run's resources costs a dozen or so `aws` calls before
    # a single delete is issued, so the budget has to be checked here too;
    # gating only the deletes would let a large backlog spend the whole job
    # timeout on describes.
    def sweep(region, tag_value)
      if AwsCleanup.expired?(@deadline)
        puts "#{region}: budget spent; leaving #{TAG_KEY}=#{tag_value} to the next run"
        return false
      end
      tally Sweep.new(cli:, region:, tag_value:, deadline: @deadline).run
      true
    end

    def stale_sweep(region)
      return if AwsCleanup.expired?(@deadline)
      values = stale_tag_values(region)
      if values.empty?
        puts "#{region}: no resources tagged with another run id"
        return
      end
      puts "#{region}: resources tagged with #{values.size} other run id(s): #{values.join(", ")}"
      values.each do |value|
        refusal = refusal_to_sweep(value)
        if refusal
          puts "  SKIP #{TAG_KEY}=#{value}: #{refusal}"
          @skipped += 1
        else
          break unless sweep(region, value)
        end
      end
    end

    # Why this run id may not be swept, or nil if it may be. A numeric tag
    # alone proves nothing: this account is shared, and anything else that
    # stamps a run id -- a deployment workflow, a staging control plane --
    # would look identical. So the id has to resolve to a finished run of
    # the workflow that creates these resources. Everything else, including
    # a run id belonging to another repository or to another workflow in
    # this one, is somebody else's and is left alone.
    def refusal_to_sweep(run_id)
      @refusals.fetch(run_id) { @refusals[run_id] = examine_run(run_id) }
    end

    def examine_run(run_id)
      run = fetch_run(run_id)
      return run if run.is_a?(String)
      if run["path"] != WORKFLOW_PATH
        "belongs to #{run["path"].inspect}, not #{WORKFLOW_PATH}"
      elsif run["status"] != "completed"
        "run status is #{run["status"].inspect}, not \"completed\""
      end
    end

    # Every Ubicloud tag value in the region that looks like a run id and is
    # not ours. Values that are not run ids -- "true" for production, a
    # username for a developer sandbox -- are never candidates.
    def stale_tag_values(region)
      tag = "Name=tag-key,Values=#{TAG_KEY}"
      found = instances(region, tag)
      DESCRIBES.each { |command, key| found.concat(describe(region, command, key, tag)) }
      found.filter_map { |resource| AwsCleanup.tag_value(resource) }
        .uniq.select { |value| RUN_TAG.match?(value) && value != @run_id }.sort
    end

    # The run as the GitHub API describes it, or a string saying why we could
    # not find out -- which includes the 404 a run id from another repository
    # returns, since run ids are unique across GitHub.
    def fetch_run(run_id)
      uri = URI.parse("#{@api_url}/repos/#{@repo}/actions/runs/#{run_id}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["Authorization"] = "Bearer #{@token}"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 10) do |http|
        http.request(request)
      end
      return "no such run in #{@repo} (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)
      run = JSON.parse(response.body)
      run.is_a?(Hash) ? run : "unreadable API response"
    rescue JSON::ParserError, IOError, SocketError, SystemCallError, Net::HTTPBadResponse, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      "unavailable (#{e.class}: #{e.message})"
    end
  end

  def self.main
    run_id = ENV["RUN_ID"].to_s.strip
    abort "RUN_ID must be set to the GitHub run id being cleaned up" unless RUN_TAG.match?(run_id)
    dry_run = !%w[0 false].include?(env("DRY_RUN", "0"))
    cli = Cli.new(dry_run:)
    identity = cli.caller_identity
    abort "AWS credentials are unusable: sts get-caller-identity failed" unless identity
    puts "Cleaning up run #{run_id} as #{identity["Arn"]} in account #{identity["Account"]}#{" (DRY RUN)" if dry_run}"
    Runner.new(
      cli:,
      run_id:,
      token: ENV["GITHUB_TOKEN"],
      repo: env("GITHUB_REPOSITORY", DEFAULT_REPO),
      api_url: env("GITHUB_API_URL", DEFAULT_API_URL),
      deadline: now + Integer(env("CLEANUP_BUDGET_SEC", "900")),
      iam_via_listing: !%w[1 true].include?(env("IAM_TAGGING", "0")),
    ).run
  end
end

AwsCleanup.main if $PROGRAM_NAME == __FILE__
