# frozen_string_literal: true

class Prog::Vnet::MaintainPresignedLoadBalancerCerts < Prog::Base
  STRAND_ID = "ffffffff-ff00-833a-8002-b05b0ec86150" # stzzzzzzzz021g01b0pres1gn1

  MIN_CERTS = 20
  MIN_WAIT_BETWEEN_CERTS_SECONDS = 60
  MAX_WAIT_SIGNING_SECONDS = 60 * 30
  OLD_CERTS_COND = Sequel[:created_at] < Sequel::CURRENT_TIMESTAMP - Sequel.cast("#{60 * 60 * 24 * 30} seconds", :interval)

  def self.schedule_strand
    Strand.where(id: STRAND_ID, label: "wait").update(schedule: Sequel::CURRENT_TIMESTAMP)
  end

  label def wait
    nap_time = frame["last_cert_created"] + MIN_WAIT_BETWEEN_CERTS_SECONDS - now
    nap(nap_time) if nap_time > 0

    # Destroy presigned certs created over 30 days ago, and remove row from presigned table.
    old_cert_ids = DB[:t]
      .with(:t, ds
        .where(OLD_CERTS_COND)
        .returning(:cert_id)
        .with_sql(:delete_sql))
      .select_map(:cert_id)
    Semaphore.incr(old_cert_ids, "destroy")

    hop_request_cert if ds.count < MIN_CERTS

    nap(60 * 60)
  end

  label def request_cert
    lb_ubid = LoadBalancer.generate_ubid
    st = Prog::Vnet::CertNexus.assemble("*.#{lb_ubid}.#{domain}", dns_zone.id, private_hostname: "*.#{lb_ubid}.private.#{domain}")
    update_stack(
      "load_balancer_id" => lb_ubid.to_uuid,
      "cert_id" => st.id,
    )
    register_deadline("wait", MAX_WAIT_SIGNING_SECONDS)
    hop_wait_for_signed_cert
  end

  label def wait_for_signed_cert
    cert_id = frame["cert_id"]
    if (cert_strand = Strand[cert_id])
      nap 10 unless cert_strand.label == "wait"
      ds.insert(load_balancer_id: frame["load_balancer_id"], cert_id: frame["cert_id"])
    else
      # Info page for visibility, as this indicates a problem in the code or a manual deletion of the strand.
      # There isn't anything that can be done in this case, and we want to keep the table populated, so hop back to wait.
      # Purposely do not resolve this page automatically, since an operator should be looking into the problem.
      cert_ubid = UBID.to_ubid(cert_id)
      Prog::PageNexus.assemble("Strand for presigned cert deleted: #{cert_ubid}",
        ["MaintainPresignedLoadBalancerCerts", cert_id],
        cert_ubid,
        severity: "info")
    end

    update_stack(
      "load_balancer_id" => nil,
      "cert_id" => nil,
      "last_cert_created" => now,
    )
    hop_wait
  end

  def now
    Time.now.to_i
  end

  def domain
    @domain ||= Config.load_balancer_service_hostname_v2
  end

  def dns_zone
    @dns_zone ||= DnsZone[project_id: Config.load_balancer_service_project_id, name: domain]
  end

  def ds
    @ds ||= DB[:presigned_load_balancer_cert]
  end
end
