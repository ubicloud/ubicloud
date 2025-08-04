# frozen_string_literal: true

require "acme-client"
require "openssl"

class Prog::Vnet::CertNexus < Prog::Base
  subject_is :cert

  REVOKE_REASON = "cessationOfOperation"

  def self.assemble(hostname, dns_zone_id)
    unless Config.development? || DnsZone[dns_zone_id]
      fail "Given DNS zone doesn't exist with the id #{dns_zone_id}"
    end

    DB.transaction do
      cert = Cert.create(hostname: hostname, dns_zone_id: dns_zone_id)

      Strand.create(prog: "Vnet::CertNexus", label: "start", stack: [{"restarted" => 0}]) { it.id = cert.id }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy unless %w[destroy].include?(strand.label)
    end
  end

  label def start
    register_deadline("wait", 10 * 60)

    if Config.development? && cert.dns_zone_id.nil?
      crt, key = Util.create_certificate(subject: "/CN=" + cert.hostname, duration: 60 * 60 * 24 * 30 * 3)
      cert.update(cert: crt, csr_key: key.to_der)
      hop_wait
    end

    account_key = OpenSSL::PKey::EC.generate("prime256v1")
    client = Acme::Client.new(private_key: account_key, directory: Config.acme_directory)
    account = client.new_account(contact: "mailto:#{Config.acme_email}", terms_of_service_agreed: true, external_account_binding: {kid: Config.acme_eab_kid, hmac_key: Config.acme_eab_hmac_key})
    order = client.new_order(identifiers: [cert.hostname])
    authorization = order.authorizations.first
    cert.update(kid: account.kid, account_key: account_key.to_der, order_url: order.url)
    dns_challenge = authorization.dns
    dns_zone.insert_record(record_name: dns_record_name, type: dns_challenge.record_type, ttl: 600, data: dns_challenge.record_content)

    hop_wait_dns_update
  end

  label def wait_dns_update
    dns_record = DnsRecord[dns_zone_id: dns_zone.id, name: dns_record_name + ".", tombstoned: false, data: dns_challenge.record_content]
    if DB[:seen_dns_records_by_dns_servers].where(dns_record_id: dns_record.id).empty?
      nap 10
    end

    dns_challenge.request_validation

    hop_wait_dns_validation
  end

  label def wait_dns_validation
    case dns_challenge.status
    when "pending", "processing"
      nap 10
    when "valid"
      cert.update(csr_key: OpenSSL::PKey::EC.generate("prime256v1").to_der)
      hop_cert_finalization
    else
      Clog.emit("DNS validation failed") { {order_status: dns_challenge.status} }
      dns_zone.delete_record(record_name: dns_record_name)
      hop_restart
    end
  end

  label def cert_finalization
    acme_order.finalize(csr: Acme::Client::CertificateRequest.new(private_key: OpenSSL::PKey::EC.new(cert.csr_key), common_name: cert.hostname))
    hop_wait_cert_finalization
  end

  label def wait_cert_finalization
    case acme_order.status
    when "processing"
      nap 10
    when "valid"
      cert.update(cert: acme_order.certificate, created_at: Time.now)

      dns_zone.delete_record(record_name: dns_record_name)
      hop_wait
    else
      Clog.emit("Certificate finalization failed") { {order_status: acme_order.status} }
      dns_zone.delete_record(record_name: dns_record_name)
      hop_restart
    end
  end

  label def wait
    if cert.created_at < Time.now - 60 * 60 * 24 * 30 * 3 # 3 months
      cert.incr_destroy
      nap 0
    end

    nap 60 * 60 * 24 * 30 # 1 month
  end

  label def restart
    when_restarted_set? do
      decr_restarted
      update_stack_restart_counter
      hop_start
    end

    cert.incr_restarted
    nap [60 * (strand.stack.first["restarted"] + 1), 60 * 10].min
  end

  label def destroy
    if Config.development? && cert.dns_zone_id.nil?
      cert.destroy
      pop "self-signed certificate destroyed"
    end

    # the reason is chosen as "cessationOfOperation"
    begin
      acme_client.revoke(certificate: cert.cert, reason: REVOKE_REASON) if cert.cert
    rescue Acme::Client::Error::AlreadyRevoked => ex
      Clog.emit("Certificate is already revoked") { {cert_revoke_failure: {ubid: cert.ubid, exception: Util.exception_to_hash(ex)}} }
    rescue Acme::Client::Error::NotFound => ex
      Clog.emit("Certificate is not found") { {cert_revoke_failure: {ubid: cert.ubid, exception: Util.exception_to_hash(ex)}} }
    rescue Acme::Client::Error::Unauthorized => ex
      if ex.message.include?("The certificate has expired and cannot be revoked")
        Clog.emit("Certificate is expired and cannot be revoked") { {cert_revoke_failure: {ubid: cert.ubid, exception: Util.exception_to_hash(ex)}} }
      else
        raise ex
      end
    end

    dns_zone.delete_record(record_name: dns_record_name) if dns_challenge
    cert.destroy
    pop "certificate revoked and destroyed"
  end

  def update_stack_restart_counter
    current_frame = strand.stack.first
    current_frame["restarted"] += 1
    strand.modified!(:stack)
    strand.save_changes
  end

  def acme_client
    # If the private_key is not yet set, we did not start the communication with
    # ACME server yet, therefore, we return nil.
    Acme::Client.new(private_key: Util.parse_key(cert.account_key), directory: Config.acme_directory, kid: cert.kid) if cert.account_key
  end

  def acme_order
    # If the order_url is set, acme_client cannot be nil, so, this is nullref safe
    acme_client.order(url: cert.order_url) if cert.order_url
  end

  def dns_challenge
    acme_order&.authorizations&.first&.dns
  end

  def dns_record_name
    dns_challenge.record_name + "." + cert.hostname
  end

  def dns_zone
    @dns_zone ||= DnsZone[cert.dns_zone_id]
  end
end
