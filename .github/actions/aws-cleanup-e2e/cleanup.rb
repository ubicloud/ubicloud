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

    def self.brief(error)
      error.to_s.lines.map(&:strip).reject(&:empty?).last || "no error output"
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

  # Drives both sweeps across every region and decides which stale run ids
  # are safe to touch.
  class Runner
    include Describe

    attr_reader :cli

    def initialize(cli:, run_id:, token:, repo: DEFAULT_REPO, api_url: DEFAULT_API_URL, deadline: nil)
      @cli = cli
      @run_id = run_id
      @token = token
      @repo = repo
      @api_url = api_url
      @deadline = deadline
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
      puts "Summary: #{cli.dry_run ? "would delete" : "deleted"} #{@deleted}, skipped #{@skipped}, failed #{@failed}"
    end

    private

    # Enumerating a run's resources costs a dozen or so `aws` calls before
    # a single delete is issued, so the budget has to be checked here too;
    # gating only the deletes would let a large backlog spend the whole job
    # timeout on describes.
    def sweep(region, tag_value)
      if AwsCleanup.expired?(@deadline)
        puts "#{region}: budget spent; leaving #{TAG_KEY}=#{tag_value} to the next run"
        return false
      end
      sweep = Sweep.new(cli:, region:, tag_value:, deadline: @deadline).run
      @deleted += sweep.deleted
      @failed += sweep.failed
      @skipped += sweep.skipped
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
    ).run
  end
end

AwsCleanup.main if $PROGRAM_NAME == __FILE__
