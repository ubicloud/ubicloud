# frozen_string_literal: true

require "acme-client"
require "openssl"

class Prog::Vnet::CertNexus < Prog::Base
  subject_is :cert
  semaphore :destroy

  def self.assemble(hostname, dns_zone_id)
    unless DnsZone[dns_zone_id]
      fail "Given DNS zone doesn't exist with the id #{dns_zone_id}"
    end

    DB.transaction do
      cert = Cert.create_with_id(hostname: hostname, dns_zone_id: dns_zone_id)

      Strand.create(prog: "Vnet::CertNexus", label: "start") { _1.id = cert.id }
    end
  end

  def before_run
    when_destroy_set? do
      hop_destroy unless %w[destroy].include?(strand.label)
    end
  end

  label def start
    register_deadline(:wait, 10 * 60)

    private_key = OpenSSL::PKey::RSA.new(4096)
    client = Acme::Client.new(private_key: private_key, directory: Config.acme_directory)
    account = client.new_account(contact: "mailto:#{Config.acme_email}", terms_of_service_agreed: true, external_account_binding: {kid: Config.acme_eab_kid, hmac_key: Config.acme_eab_hmac_key})
    order = client.new_order(identifiers: [cert.hostname])
    authorization = order.authorizations.first
    cert.update(kid: account.kid, private_key: private_key.to_s, order_url: order.url)
    dns_challenge = authorization.dns
    dns_zone.insert_record(record_name: "#{dns_challenge.record_name}.#{cert.hostname}", type: dns_challenge.record_type, ttl: 600, data: dns_challenge.record_content)

    hop_wait_dns_update
  end

  label def wait_dns_update
    dns_record = DnsRecord[dns_zone_id: dns_zone.id, name: "#{dns_challenge.record_name}.#{cert.hostname}.", tombstoned: false]
    if DB[:seen_dns_records_by_dns_servers].where(dns_record_id: dns_record.id).all.empty?
      nap 10
    end

    dns_challenge.request_validation

    hop_wait_dns_validation
  end

  label def wait_dns_validation
    case dns_challenge.status
    when "pending"
      nap 10
    when "valid"
      csr_key = OpenSSL::PKey::RSA.new(4096)
      csr = Acme::Client::CertificateRequest.new(private_key: csr_key, common_name: cert.hostname)
      acme_order.finalize(csr: csr)
      cert.update(csr_key: csr_key.to_s)

      hop_wait_cert_finalization
    else
      fail "DNS validation failed"
    end
  end

  label def wait_cert_finalization
    case acme_order.status
    when "processing"
      nap 10
    when "valid"
      cert.update(cert: acme_order.certificate, created_at: Time.now)

      dns_zone.delete_record(record_name: "#{dns_challenge.record_name}.#{cert.hostname}")
      hop_wait
    else
      fail "Certificate finalization failed"
    end
  end

  label def wait
    if cert.created_at < Time.now - 60 * 60 * 24 * 30 * 3 # 3 months
      hop_destroy
    end

    nap 60 * 60 * 24 * 30 # 1 month
  end

  label def destroy
    begin
      acme_client.revoke(certificate: cert.cert) if cert.cert
    rescue Acme::Client::Error::AlreadyRevoked
      Clog.emit("Certificate is already revoked")
    rescue Sequel::Error
      fail "Failed to revoke certificate"
    end

    dns_zone.delete_record(record_name: "#{dns_challenge.record_name}.#{cert.hostname}") if dns_challenge
    cert.destroy
    pop "certificate revoked and destroyed"
  end

  def acme_client
    Acme::Client.new(private_key: OpenSSL::PKey::RSA.new(cert.private_key), directory: Config.acme_directory, kid: cert.kid)
  rescue
    nil
  end

  def acme_order
    acme_client&.order(url: cert.order_url)
  end

  def dns_challenge
    acme_order&.authorizations&.first&.dns
  end

  def dns_zone
    @dns_zone ||= DnsZone[cert.dns_zone_id]
  end
end
