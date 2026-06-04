# frozen_string_literal: true

require "resolv"

class Prog::Test::DnsZone < Prog::Test::Base
  semaphore :destroy_and_verify
  frame_reader :zone_name, :project_id
  frame_accessor :dns_zone_id, :dns_server_id, :setup_strand_id,
    :cloudflare_zone_id, :cloudflare_record_ids, :sentinel_record_name

  PUBLIC_RESOLVERS = ["1.1.1.1", "8.8.8.8"].freeze
  # We want this as low as possible so back-to-back e2e runs don't wait on stale recursive
  # caches still serving the previous run's Knot VM IP.
  CLOUDFLARE_RECORD_TTL = 60
  # Sentinel record values used by wait_dns_propagation. RFC 5737 / RFC 3849
  # reserve these address ranges for documentation, so they can never be a
  # real backend.
  SENTINEL_RECORD_IP4 = "203.0.113.1"
  SENTINEL_RECORD_IP6 = "2001:db8::1"

  def self.assemble(zone_name, project_id)
    fail "zone_name must be set" if zone_name.to_s.strip.empty?
    fail "Config.dns_service_project_id must be set" if Config.dns_service_project_id.nil?
    fail "Config.e2e_cloudflare_api_token must be set" if Config.e2e_cloudflare_api_token.nil? || Config.e2e_cloudflare_api_token.empty?
    fail "Config.e2e_cloudflare_parent_zone_name must be set" if Config.e2e_cloudflare_parent_zone_name.nil? || Config.e2e_cloudflare_parent_zone_name.empty?
    fail "Provided project_id does not exist" unless Project[project_id]

    Project[Config.dns_service_project_id] ||
      Project.create_with_id(Config.dns_service_project_id, name: "Dns-Service-Project")

    Strand.create(prog: "Test::DnsZone", label: "start", stack: [{"zone_name" => zone_name, "project_id" => project_id}])
  end

  label def start
    ds = DnsServer.create(name: ns_name)
    dz = DnsZone.create(
      name: zone_name,
      project_id:,
      neg_ttl: 30,
      last_purged_at: Time.now,
    )
    dz.add_dns_server(ds)
    Strand.create_with_id(dz.id, prog: "DnsZone::DnsZoneNexus", label: "wait")

    setup_st = Prog::DnsZone::SetupDnsServerVm.assemble(ds, name: "dns-e2e")

    self.dns_zone_id = dz.id
    self.dns_server_id = ds.id
    self.setup_strand_id = setup_st.id

    hop_wait_setup
  end

  label def wait_setup
    nap 10 if Strand[setup_strand_id]
    hop_register_cloudflare_records
  end

  label def register_cloudflare_records
    parent_zone_id = cloudflare_client.zone_id_by_name(Config.e2e_cloudflare_parent_zone_name)

    a_record_id = cloudflare_client.ensure_dns_record(parent_zone_id, type: "A", name: ns_name, content: knot_vm.ip4.to_s, ttl: CLOUDFLARE_RECORD_TTL)
    aaaa_record_id = cloudflare_client.ensure_dns_record(parent_zone_id, type: "AAAA", name: ns_name, content: knot_vm.ip6.to_s, ttl: CLOUDFLARE_RECORD_TTL)
    ns_record_id = cloudflare_client.ensure_dns_record(parent_zone_id, type: "NS", name: zone_name, content: ns_name, ttl: CLOUDFLARE_RECORD_TTL)

    self.cloudflare_zone_id = parent_zone_id
    self.cloudflare_record_ids = [a_record_id, aaaa_record_id, ns_record_id]

    hop_insert_sentinel_records
  end

  label def insert_sentinel_records
    # Insert a sentinel A/AAAA pair into our delegated zone using a fresh
    # random prefix per run. wait_dns_propagation resolves these through
    # public resolvers to confirm the full chain is up. The random prefix
    # ensures we are not using the previous run's cached response.
    sentinel_name = "_e2e_check_#{SecureRandom.alphanumeric(8).downcase}.#{zone_name}"
    dns_zone.insert_record(record_name: sentinel_name, type: "A", ttl: CLOUDFLARE_RECORD_TTL, data: SENTINEL_RECORD_IP4)
    dns_zone.insert_record(record_name: sentinel_name, type: "AAAA", ttl: CLOUDFLARE_RECORD_TTL, data: SENTINEL_RECORD_IP6)
    self.sentinel_record_name = sentinel_name
    hop_wait_dns_propagation
  end

  label def wait_dns_propagation
    sentinel_name = sentinel_record_name
    seen = PUBLIC_RESOLVERS.all? do |resolver_ip|
      Resolv::DNS.open(nameserver: [resolver_ip]) do |dns|
        dns.timeouts = 3
        dns.getresources(sentinel_name, Resolv::DNS::Resource::IN::A).any? { it.address.to_s == SENTINEL_RECORD_IP4 } &&
          dns.getresources(sentinel_name, Resolv::DNS::Resource::IN::AAAA).any? { it.address.to_s == SENTINEL_RECORD_IP6 }
      end
    rescue Resolv::ResolvError, Resolv::ResolvTimeout
      false
    end

    hop_wait if seen
    nap 10
  end

  label def wait
    hop_trigger_destroy if destroy_and_verify_set?
    nap 10
  end

  label def trigger_destroy
    cloudflare_client.delete_dns_records(cloudflare_zone_id, cloudflare_record_ids)
    dns_server.retire_vm(knot_vm.id, force: true)
    hop_wait_destroy
  end

  label def wait_destroy
    DB[:seen_dns_records_by_dns_servers].where(dns_record_id: dns_zone.records_dataset.select(:id)).delete
    dns_zone.records_dataset.destroy
    DB[:dns_servers_dns_zones].where(dns_zone_id: dns_zone.id).delete
    dns_zone.strand.semaphores_dataset.destroy
    # DnsZoneNexus has no destroy label, so we tear the strand and zone down directly.
    dns_zone.strand.destroy
    dns_zone.destroy
    dns_server.destroy
    pop "Dns infrastructure destroyed"
  end

  label def failed
    nap 15
  end

  def ns_name
    "ns-e2e.#{Config.e2e_cloudflare_parent_zone_name}"
  end

  def dns_zone
    @dns_zone ||= DnsZone[dns_zone_id]
  end

  def dns_server
    @dns_server ||= DnsServer[dns_server_id]
  end

  def knot_vm
    dns_server.vms.first
  end

  def cloudflare_client
    @cloudflare_client ||= CloudflareClient.new(Config.e2e_cloudflare_api_token)
  end
end
