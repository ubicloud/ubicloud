# frozen_string_literal: true

require "aws-sdk-ec2"

class Prog::LocationNexus < Prog::Base
  subject_is :location

  LEAD_SECONDS = 48 * 60 * 60     # provision the replacement standby this far ahead
  BYPASS_SECONDS = 24 * 60 * 60   # inside this, skip the customer window and fail over now

  def self.assemble(**)
    DB.transaction do
      location = Location.create(**)
      Strand.create_with_id(location, prog: "LocationNexus", label: "wait")
    end
  end

  label def wait
    now = Time.now
    location.scheduled_maintenance_events.each do |vm_id, not_before|
      next if not_before - now > LEAD_SECONDS
      next unless (server = PostgresServer.first(vm_id:))
      # An ephemeral database cannot fail over: a replacement server would be
      # seeded from a base backup its timeline does not take. Setting recycle
      # would sit unserviced forever; let the maintenance event hit the VM.
      next if server.resource.ephemeral

      unless server.recycle_set?
        server.incr_recycle
        Clog.emit("scheduled postgres failover for cloud maintenance", {ubid: server.ubid, provider: location.provider, vm_id:, not_before:})
      end

      if not_before - now <= BYPASS_SECONDS && !server.resource.bypass_maintenance_window_set?
        server.resource.incr_bypass_maintenance_window
      end
    end

    if Config.pg_network_metering_enabled && (location.aws? || location.gcp?)
      refresh_provider_ip_ranges if refresh_provider_ip_ranges_set? || provider_ip_ranges_stale?
    end

    nap 3600
  rescue Aws::EC2::Errors::UnauthorizedOperation => e
    Clog.emit("AWS UnauthorizedOperation error when checking for scheduled maintenance events", Util.exception_to_hash(e, into: {location_id: location.id}))
    # This is a known issue with AWS accounts that don't have the right permissions to describe maintenance events.
    Prog::PageNexus.assemble("aws_unauthorized_operation", ["AwsUnauthorizedOperation", location.ubid], location.ubid, severity: "warning", extra_data: {project: location.project.ubid})
    nap 3600 * 24 * 31
  end

  def provider_ip_ranges_stale?
    location.provider_ip_ranges_dataset
      .where { refreshed_at > Sequel::CURRENT_TIMESTAMP - Sequel.cast("1 day", :interval) }
      .empty?
  end

  def refresh_provider_ip_ranges
    feeder = {"aws" => NetworkMetering::Provider::Aws, "gcp" => NetworkMetering::Provider::Gcp}.fetch(location.provider).new
    raw = begin
      feeder.fetch_ranges
    rescue Excon::Error, JSON::ParserError => e
      Clog.emit("failed to fetch provider ip ranges", Util.exception_to_hash(e, into: {location: location.name, provider: location.provider}))
      return
    end
    now = Time.now
    drift = false
    feeder.classify_ranges(raw, location.metering_region, {}).each do |key, buckets|
      ip_version = Integer(key[1..])
      buckets.each do |bucket_id, new_cidrs|
        row = ProviderIpRange.find_or_new(location_id: location.id, bucket_id:, ip_version:)
        if row.new? || row.cidrs.map(&:to_s).sort != new_cidrs.sort
          row.set(cidrs: new_cidrs, refreshed_at: now).save_changes
          drift = true
        else
          row.update(refreshed_at: now)
        end
      end
    end
    if drift
      ids = location.postgres_resources.flat_map { |r| r.servers.map(&:id) }
      if ids.any?
        # Fresh CIDRs are inert until each server re-composes config.json.
        # Spread the incr_configure_metrics bumps to avoid a fleet-wide stampede;
        # auto_exit lets the rollout strand pop itself when done.
        Prog::RolloutSemaphore.assemble(
          semaphore: :configure_metrics, ids:, gap: 5, initial_gap: 5, wait: false, auto_exit: true,
        )
      end
    end
    decr_refresh_provider_ip_ranges
  end

  label def destroy
    decr_destroy
    location.destroy
    pop "location destroyed"
  end
end
