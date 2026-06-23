# frozen_string_literal: true

class Prog::Vnet::MaintainPresignedCerts < Prog::Base
  frame_accessor :cert_id, :last_cert_created

  MIN_CERTS = 20
  MIN_WAIT_BETWEEN_CERTS_SECONDS = 60
  MAX_WAIT_SIGNING_SECONDS = 60 * 30
  OLD_CERTS_COND = Sequel[:created_at] < Sequel::CURRENT_TIMESTAMP - Sequel.cast("#{60 * 60 * 24 * 30} seconds", :interval)

  def self.schedule_strand
    Strand.where(id: self::STRAND_ID, label: "wait").update(schedule: Sequel::CURRENT_TIMESTAMP)
  end

  def wait
    nap_time = last_cert_created + MIN_WAIT_BETWEEN_CERTS_SECONDS - now
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

  def request_cert
    ubid = generate_ubid
    st = Prog::Vnet::CertNexus.assemble("*.#{ubid}.#{domain}", dns_zone.id,
      private_hostname: "*.#{ubid}.private.#{domain}",
      waiting_strand_id: strand.id)
    self.resource_id = ubid.to_uuid
    self.cert_id = st.id
    self.last_cert_created = now
    register_deadline("wait", MAX_WAIT_SIGNING_SECONDS + 15 * 60)
    hop_wait_for_signed_cert
  end

  def wait_for_signed_cert
    if (cert_strand = Strand[cert_id])
      if cert_strand.label == "wait"
        ds.insert(id_key.to_sym => resource_id, :cert_id => cert_id)
      elsif now - last_cert_created < MAX_WAIT_SIGNING_SECONDS
        nap(10 * 60)
      else
        Clog.emit("Strand for presigned cert not finished in time, destroying", {"presigned_cert_strand_destroyed" => UBID.to_ubid(cert_id)})
        cert_strand.subject.incr_destroy
      end
    else
      # There isn't anything that can be done in this case, and we want to keep the table populated,
      # so hop back to wait. Emit so it's possible to track cases where this has happened.
      Clog.emit("Strand for presigned cert deleted", {"presigned_cert_strand_deleted" => UBID.to_ubid(cert_id)})
    end

    self.resource_id = nil
    self.cert_id = nil
    self.last_cert_created = now
    hop_wait
  end

  def now
    Time.now.to_i
  end
end
