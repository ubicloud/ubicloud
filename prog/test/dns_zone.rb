# frozen_string_literal: true

require "resolv"

class Prog::Test::DnsZone < Prog::Test::Base
  semaphore :destroy_and_verify

  PUBLIC_RESOLVERS = ["1.1.1.1", "8.8.8.8"].freeze
  # We want this as low as possible so back-to-back e2e runs don't wait on stale recursive
  # caches still serving the previous run's Knot VM IP.
  CLOUDFLARE_RECORD_TTL = 60

  def self.assemble
    zone_name = Config.kubernetes_service_hostname
    fail "Config.kubernetes_service_hostname must be set" if zone_name.nil? || zone_name.empty?
    fail "Config.dns_service_project_id must be set" if Config.dns_service_project_id.nil?
    fail "Config.e2e_cloudflare_api_token must be set" if Config.e2e_cloudflare_api_token.nil? || Config.e2e_cloudflare_api_token.empty?
    fail "Config.e2e_cloudflare_parent_zone_name must be set" if Config.e2e_cloudflare_parent_zone_name.nil? || Config.e2e_cloudflare_parent_zone_name.empty?

    Project[Config.dns_service_project_id] ||
      Project.create_with_id(Config.dns_service_project_id, name: "Dns-Service-Project")
    Project[Config.kubernetes_service_project_id] ||
      Project.create_with_id(Config.kubernetes_service_project_id, name: "Ubicloud-Kubernetes-Resources")

    Strand.create(prog: "Test::DnsZone", label: "start", stack: [{"zone_name" => zone_name}])
  end

  label def start
    ds = DnsServer.create(name: ns_name)
    dz = DnsZone.create(
      name: frame["zone_name"],
      project_id: Config.kubernetes_service_project_id,
      neg_ttl: 30,
      last_purged_at: Time.now,
    )
    dz.add_dns_server(ds)
    Strand.create_with_id(dz.id, prog: "DnsZone::DnsZoneNexus", label: "wait")

    setup_st = Prog::DnsZone::SetupDnsServerVm.assemble(ds, name: "dns-e2e")

    update_stack({
      "dns_zone_id" => dz.id,
      "dns_server_id" => ds.id,
      "setup_strand_id" => setup_st.id,
    })

    hop_wait_setup
  end

  label def wait_setup
    nap 10 if Strand[frame["setup_strand_id"]]
    hop_register_cloudflare_records
  end

  label def register_cloudflare_records
    vm = knot_vm
    fail "Knot VM is missing after setup" unless vm

    parent_zone_id = cloudflare_client.zone_id_by_name(Config.e2e_cloudflare_parent_zone_name)

    a_record_id = cloudflare_client.create_dns_record(parent_zone_id, type: "A", name: ns_name, content: vm.ip4.to_s, ttl: CLOUDFLARE_RECORD_TTL)
    aaaa_record_id = cloudflare_client.create_dns_record(parent_zone_id, type: "AAAA", name: ns_name, content: vm.ip6.to_s, ttl: CLOUDFLARE_RECORD_TTL)
    ns_record_id = cloudflare_client.create_dns_record(parent_zone_id, type: "NS", name: frame["zone_name"], content: ns_name, ttl: CLOUDFLARE_RECORD_TTL)

    update_stack({
      "cloudflare_zone_id" => parent_zone_id,
      "cloudflare_record_ids" => [a_record_id, aaaa_record_id, ns_record_id],
    })

    hop_wait_dns_propagation
  end

  label def wait_dns_propagation
    # Cloudflare returns immediately on POST, but recursive resolvers may still
    # be serving a previous run's records (or a negative cache) until TTL expiry.
    # Resolve the nameserver through each public resolver and confirm the A record
    # matches the current Knot VM's IPv4. Verifying the value (not just
    # existence) is what makes this safe across back-to-back runs: a stale cache
    # would return an IP that doesn't match and we'd nap until it expires.
    vm = knot_vm
    fail "Knot VM is missing while waiting for DNS propagation" unless vm
    expected_ip = vm.ip4.to_s

    seen = PUBLIC_RESOLVERS.all? do |resolver_ip|
      Resolv::DNS.open(nameserver: [resolver_ip]) do |dns|
        dns.timeouts = 3
        dns.getresources(ns_name, Resolv::DNS::Resource::IN::A).any? { it.address.to_s == expected_ip }
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
    delete_cloudflare_records
    ds = DnsServer[frame["dns_server_id"]]
    vm = ds.vms.first
    ds.retire_vm(vm.id, force: true) if vm
    hop_wait_destroy
  end

  label def wait_destroy
    if (dz = DnsZone[frame["dns_zone_id"]])
      DB[:seen_dns_records_by_dns_servers].where(dns_record_id: dz.records_dataset.select(:id)).delete(force: true)
      dz.records.each(&:destroy)
      DB[:dns_servers_dns_zones].where(dns_zone_id: dz.id).delete(force: true)
      zone_strand = Strand[dz.id]
      zone_strand.semaphores_dataset.destroy
      zone_strand.destroy
      dz.destroy
    end
    DnsServer[frame["dns_server_id"]]&.destroy

    pop "Dns infrastructure destroyed"
  end

  label def failed
    nap 15
  end

  def ns_name
    "ns-e2e.#{Config.e2e_cloudflare_parent_zone_name}"
  end

  def knot_vm
    DnsServer[frame["dns_server_id"]]&.vms&.first
  end

  def cloudflare_client
    @cloudflare_client ||= CloudflareClient.new(Config.e2e_cloudflare_api_token)
  end

  def delete_cloudflare_records
    zone_id = frame["cloudflare_zone_id"]
    record_ids = frame["cloudflare_record_ids"] || []
    return if zone_id.nil? || record_ids.empty?

    record_ids.each { cloudflare_client.delete_dns_record(zone_id, it) }
  end
end
