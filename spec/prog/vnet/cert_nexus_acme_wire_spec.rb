# frozen_string_literal: true

require_relative "../../common/acme_wire"

# Wire-level CA behavior: WebMock returns complete ACME HTTP responses
# and the real acme-client gem parses them. Examples marked "STAGING"
# rest on fixtures inferred from documentation; verify them against
# dv.acme-v02.test-api.pki.goog before enabling Google Trust Services in
# production.
RSpec.describe Prog::Vnet::CertNexus do
  include AcmeWire::Helpers

  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }
  let(:dns_zone) { DnsZone.create(name: "test-dns-zone.com", project_id: project.id) }
  let(:hostname) { "cert-hostname.test-dns-zone.com" }
  let(:st) { described_class.assemble(hostname, dns_zone.id) }
  let(:cert) { st.subject }
  let(:account_key) { OpenSSL::PKey::EC.generate("prime256v1") }

  def wire_provider(profile, email: "ops@example.com", eab_kid: nil, eab_hmac_key: nil, **overrides)
    AcmeProvider.create(name: "wire-#{profile.name}", directory_url: profile.directory_url,
      email:, eab_kid:, eab_hmac_key:, priority: 0, **overrides)
  end

  def seed_shared_account(provider, profile)
    AcmeAccount.create(acme_provider_id: provider.id, account_key: account_key.to_der, kid: profile.account_url)
  end

  def fresh_prog
    described_class.new(st)
  end

  describe "account registration over the wire" do
    it "registers at Let's Encrypt without EAB, using a jwk-mode ES256 JWS" do
      profile = AcmeWire::LETS_ENCRYPT
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      captured = nil
      stub_request(:post, profile.new_account_url)
        .with { |req|
          captured = req
          true
        }
        .to_return(status: 201, headers: acme_headers("Location" => profile.account_url),
          body: JSON.generate({"status" => "valid", "contact" => ["mailto:ops@example.com"]}))

      account = AcmeAccount.fetch_or_register(wire_provider(profile))

      expect(account.kid).to eq profile.account_url
      protected_header, payload, = decode_jws(captured)
      expect(protected_header["alg"]).to eq "ES256"
      expect(protected_header["url"]).to eq profile.new_account_url
      expect(protected_header["jwk"]).to include("kty" => "EC", "crv" => "P-256")
      expect(protected_header).not_to have_key("kid")
      expect(protected_header["nonce"]).to match(/\A(head-)?nonce-/)
      expect(payload).to eq({"contact" => ["mailto:ops@example.com"], "termsOfServiceAgreed" => true})
    end

    it "sends an empty contact array when the provider has no email" do
      profile = AcmeWire::LETS_ENCRYPT
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      captured = nil
      stub_request(:post, profile.new_account_url)
        .with { |req|
          captured = req
          true
        }
        .to_return(status: 201, headers: acme_headers("Location" => profile.account_url), body: JSON.generate({"status" => "valid"}))

      AcmeAccount.fetch_or_register(wire_provider(profile, email: nil))

      _, payload, = decode_jws(captured)
      expect(payload).to eq({"contact" => [], "termsOfServiceAgreed" => true})
    end

    it "registers at GTS with a verifiable HS256 external account binding" do
      profile = AcmeWire::GTS
      hmac_secret = SecureRandom.bytes(32)
      eab_hmac_key = Base64.urlsafe_encode64(hmac_secret)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      captured = nil
      stub_request(:post, profile.new_account_url)
        .with { |req|
          captured = req
          true
        }
        .to_return(status: 201, headers: acme_headers("Location" => profile.account_url), body: JSON.generate({"status" => "valid"}))

      account = AcmeAccount.fetch_or_register(wire_provider(profile, eab_kid: "gts-eab-kid", eab_hmac_key:))

      expect(account.kid).to eq profile.account_url
      protected_header, payload, = decode_jws(captured)
      eab = payload.fetch("externalAccountBinding")
      inner_header = JSON.parse(b64u_decode(eab["protected"]))
      expect(inner_header).to eq({"alg" => "HS256", "typ" => "JWT", "kid" => "gts-eab-kid", "url" => profile.new_account_url})
      expect(JSON.parse(b64u_decode(eab["payload"]))).to eq protected_header["jwk"]
      expected_signature = Base64.urlsafe_encode64(
        OpenSSL::HMAC.digest("SHA256", hmac_secret, "#{eab["protected"]}.#{eab["payload"]}"),
      ).delete("=")
      expect(eab["signature"]).to eq expected_signature
    end

    it "raises ExternalAccountRequired on GTS's verbatim missing-EAB response" do
      profile = AcmeWire::GTS
      provider = wire_provider(profile)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      stub_acme_json(:post, profile.new_account_url,
        profile.error_body(
          type: "urn:ietf:params:acme:error:externalAccountRequired",
          detail: "External Account Binding is required for new accounts. See https://tools.ietf.org/html/rfc8555#section-7.3.4 for more information.",
        ), status: 400)

      expect {
        AcmeAccount.fetch_or_register(provider)
      }.to raise_error(Acme::Client::Error::ExternalAccountRequired, /External Account Binding is required/)
      expect(AcmeAccount.where(acme_provider_id: provider.id)).to be_empty
    end

    it "raises Unauthorized on GTS EAB verification failure (STAGING: consumed-secret body inferred)" do
      profile = AcmeWire::GTS
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      stub_acme_json(:post, profile.new_account_url,
        profile.error_body(type: "urn:ietf:params:acme:error:unauthorized", detail: "External Account Binding JWS verification failed"),
        status: 403)

      expect {
        AcmeAccount.fetch_or_register(wire_provider(profile, eab_kid: "used-kid", eab_hmac_key: Base64.urlsafe_encode64(SecureRandom.bytes(32))))
      }.to raise_error(Acme::Client::Error::Unauthorized, /verification failed/)
    end

    it "retries transparently when badNonce arrives with a fresh Replay-Nonce" do
      profile = AcmeWire::LETS_ENCRYPT
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      stub_request(:post, profile.new_account_url).to_return(
        {status: 400, headers: acme_headers, body: JSON.generate(profile.error_body(type: "urn:ietf:params:acme:error:badNonce", detail: "JWS has invalid anti-replay nonce"))},
        {status: 201, headers: acme_headers("Location" => profile.account_url), body: JSON.generate({"status" => "valid"})},
      )

      account = AcmeAccount.fetch_or_register(wire_provider(profile))

      expect(account.kid).to eq profile.account_url
      expect(WebMock).to have_requested(:post, profile.new_account_url).twice
    end
  end

  shared_examples "issues a certificate over the wire" do
    it "walks issuance end to end with correct DNS content, CSR, and stored chain" do
      order_request = nil
      stub_request(:post, profile.new_order_url)
        .with { |req|
          order_request = req
          true
        }
        .to_return(status: 201, headers: acme_headers("Location" => profile.order_url),
          body: JSON.generate(acme_order_body(profile, status: "pending", identifiers: [hostname])))
      stub_acme_json(:post, profile.authz_url, acme_authz_body(profile, status: "pending", domain: hostname, challenge_status: "pending"))

      expect { fresh_prog.start }.to hop("wait_dns_update")

      protected_header, payload, = decode_jws(order_request)
      expect(protected_header["kid"]).to eq profile.account_url
      expect(protected_header).not_to have_key("jwk")
      expect(payload).to eq({"identifiers" => [{"type" => "dns", "value" => hostname}]})
      expect(cert.reload.acme_provider_id).to eq provider.id
      record = DnsRecord.first(name: "_acme-challenge.#{hostname}.", tombstoned: false)
      expect(record.data).to eq expected_txt_content(account_key)

      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: record.id, dns_server_id: nil)
      stub_acme_json(:post, profile.order_url, acme_order_body(profile, status: "pending", identifiers: [hostname]))
      stub_acme_json(:post, profile.challenge_url, {"type" => "dns-01", "url" => profile.challenge_url, "status" => "processing", "token" => AcmeWire::DEFAULT_TOKEN})

      expect { fresh_prog.wait_dns_update }.to hop("wait_dns_validation")

      stub_acme_json(:post, profile.authz_url, acme_authz_body(profile, status: "valid", domain: hostname, challenge_status: "valid"))

      expect { fresh_prog.wait_dns_validation }.to hop("cert_finalization")
      expect(cert.reload.csr_key).not_to be_nil

      finalize_request = nil
      stub_request(:post, profile.finalize_url)
        .with { |req|
          finalize_request = req
          true
        }
        .to_return(status: 200, headers: acme_headers("Location" => profile.order_url),
          body: JSON.generate(acme_order_body(profile, status: "processing", identifiers: [hostname])))

      expect { fresh_prog.cert_finalization }.to hop("wait_cert_finalization")

      _, finalize_payload, = decode_jws(finalize_request)
      csr = OpenSSL::X509::Request.new(b64u_decode(finalize_payload.fetch("csr")))
      expect(csr.verify(csr.public_key)).to be true
      expect(csr.subject.to_a.assoc("CN")[1]).to eq hostname
      expect(csr.to_der).to include(hostname)

      pem = acme_pem_chain(hostname)
      stub_acme_json(:post, profile.order_url, acme_order_body(profile, status: "valid", identifiers: [hostname], certificate: profile.cert_url))
      stub_request(:post, profile.cert_url)
        .to_return(status: 200, headers: {"Replay-Nonce" => "n", "Content-Type" => "application/pem-certificate-chain"}, body: pem)

      expect { fresh_prog.wait_cert_finalization }.to hop("wait")
      expect(cert.reload.cert).to eq pem
      expect(cert.cert.scan("BEGIN CERTIFICATE").size).to eq 2
      expect(DnsRecord.where(name: "_acme-challenge.#{hostname}.", data: record.data, tombstoned: true).count).to eq 1
    end

    it "creates the TXT record under the stripped domain for wildcard orders" do
      wildcard = "*.abc.test-dns-zone.com"
      cert.update(hostname: wildcard)
      stub_acme_json(:post, profile.new_order_url,
        acme_order_body(profile, status: "pending", identifiers: [wildcard]), status: 201, headers: {"Location" => profile.order_url})
      # Both CAs return the identifier with the *. prefix stripped plus
      # wildcard: true. Documented for Let's Encrypt; STAGING for GTS.
      stub_acme_json(:post, profile.authz_url,
        acme_authz_body(profile, status: "pending", domain: "abc.test-dns-zone.com", challenge_status: "pending", wildcard: true))

      expect { fresh_prog.start }.to hop("wait_dns_update")
      expect(DnsRecord.first(name: "_acme-challenge.abc.test-dns-zone.com.", tombstoned: false)).not_to be_nil
    end

    it "hops to restart when validation fails with a dns problem document" do
      stub_acme_json(:post, profile.new_order_url,
        acme_order_body(profile, status: "pending", identifiers: [hostname]), status: 201, headers: {"Location" => profile.order_url})
      stub_acme_json(:post, profile.authz_url, acme_authz_body(profile, status: "pending", domain: hostname, challenge_status: "pending"))
      expect { fresh_prog.start }.to hop("wait_dns_update")

      stub_acme_json(:post, profile.order_url, acme_order_body(profile, status: "invalid", identifiers: [hostname]))
      stub_acme_json(:post, profile.authz_url,
        acme_authz_body(profile, status: "invalid", domain: hostname, challenge_status: "invalid",
          error: {"type" => "urn:ietf:params:acme:error:dns", "detail" => "DNS problem: NXDOMAIN looking up TXT for _acme-challenge.#{hostname}"}))

      expect { fresh_prog.wait_dns_validation }.to hop("restart")
    end
  end

  describe "issuance against Let's Encrypt fixtures" do
    let(:profile) { AcmeWire::LETS_ENCRYPT }
    let(:provider) { wire_provider(profile) }

    before do
      seed_shared_account(provider, profile)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
    end

    it_behaves_like "issues a certificate over the wire"

    it "rotates the restarted certificate onto the next enabled provider" do
      fallback_profile = AcmeWire::GTS
      fallback = AcmeProvider.create(name: "wire-fallback", directory_url: fallback_profile.directory_url, priority: 1)
      AcmeAccount.create(acme_provider_id: fallback.id, account_key: account_key.to_der, kid: fallback_profile.account_url)
      stub_acme_directory(fallback_profile)
      stub_acme_nonce(fallback_profile)
      cert.update(acme_provider_id: provider.id)
      refresh_frame(nx, new_values: {"restarted" => 1})
      stub_acme_json(:post, fallback_profile.new_order_url,
        acme_order_body(fallback_profile, status: "pending", identifiers: [hostname]), status: 201, headers: {"Location" => fallback_profile.order_url})
      stub_acme_json(:post, fallback_profile.authz_url, acme_authz_body(fallback_profile, status: "pending", domain: hostname, challenge_status: "pending"))

      expect { fresh_prog.start }.to hop("wait_dns_update")

      expect(cert.reload.acme_provider_id).to eq fallback.id
      expect(WebMock).not_to have_requested(:post, profile.new_order_url)
    end

    it "raises RateLimited with Retry-After on the verbatim new-order limit response" do
      stub_acme_json(:post, profile.new_order_url,
        profile.error_body(
          type: "urn:ietf:params:acme:error:rateLimited",
          detail: "too many new orders recently (300) for this account, retry after 2026-01-25 18:30:00 UTC",
        ), status: 429, headers: {"Retry-After" => "3600"})

      expect { fresh_prog.start }.to raise_error(Acme::Client::Error::RateLimited) do |ex|
        expect(ex.retry_after).to be_between(3590, 3600)
      end
    end
  end

  describe "issuance against Google Trust Services fixtures" do
    let(:profile) { AcmeWire::GTS }
    let(:provider) { wire_provider(profile) }

    before do
      seed_shared_account(provider, profile)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
    end

    it_behaves_like "issues a certificate over the wire"

    it "raises RateLimited when quota exhaustion uses the standard problem type" do
      stub_acme_json(:post, profile.new_order_url,
        profile.error_body(type: "urn:ietf:params:acme:error:rateLimited", detail: "Quota exceeded for new-order requests"),
        status: 429, headers: {"Retry-After" => "60"})

      expect { fresh_prog.start }.to raise_error(Acme::Client::Error::RateLimited)
    end

    it "surfaces a nonstandard quota problem type as the base error class (STAGING: capture real type)" do
      stub_acme_json(:post, profile.new_order_url,
        profile.error_body(type: "type.googleapis.com/google.rpc.QuotaFailure", detail: "Quota exceeded"),
        status: 429, headers: {"Retry-After" => "60"})

      expect { fresh_prog.start }.to raise_error(Acme::Client::Error) do |ex|
        expect(ex.class).to eq Acme::Client::Error
      end
    end
  end

  describe "revocation over the wire" do
    def prepare_revocable_cert(profile, shared: true)
      provider = wire_provider(profile)
      pem = acme_pem_chain(hostname)
      if shared
        seed_shared_account(provider, profile)
        cert.update(acme_provider_id: provider.id, kid: profile.account_url, cert: pem)
      else
        cert.update(acme_provider_id: provider.id, kid: profile.account_url, account_key: account_key.to_der, cert: pem)
      end
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      [provider, pem]
    end

    it "revokes with reason cessationOfOperation via the shared account and destroys the cert" do
      profile = AcmeWire::LETS_ENCRYPT
      _, pem = prepare_revocable_cert(profile)
      revoke_request = nil
      stub_request(:post, profile.revoke_url)
        .with { |req|
          revoke_request = req
          true
        }
        .to_return(status: 200, headers: acme_headers, body: "")

      expect { fresh_prog.destroy }.to exit({"msg" => "certificate revoked and destroyed"})

      protected_header, payload, = decode_jws(revoke_request)
      expect(protected_header["kid"]).to eq profile.account_url
      expect(payload["reason"]).to eq "cessationOfOperation"
      der = OpenSSL::X509::Certificate.new(pem).to_der
      expect(b64u_decode(payload["certificate"])).to eq der
      expect(cert).not_to exist
    end

    it "continues on alreadyRevoked" do
      profile = AcmeWire::LETS_ENCRYPT
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "urn:ietf:params:acme:error:alreadyRevoked", detail: "Certificate has already been revoked"), status: 400)

      expect { fresh_prog.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "continues on Let's Encrypt's current expired-certificate response" do
      profile = AcmeWire::LETS_ENCRYPT
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "urn:ietf:params:acme:error:unauthorized", detail: "Unable to revoke :: Certificate is expired"),
        status: 403)

      expect { fresh_prog.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "re-raises a GTS refusal under an unmapped problem type (STAGING: real type and wording unobserved)" do
      # Only the RFC 8555 unauthorized type counts as an expiry refusal.
      # If GTS turns out to use another type, add it with a captured
      # body; do not widen the rescue in advance.
      profile = AcmeWire::GTS
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "type.googleapis.com/google.rpc.FailedPrecondition", detail: "Certificate has expired"),
        status: 403)

      expect { fresh_prog.destroy }.to raise_error Acme::Client::Error
      expect(cert).to exist
    end

    it "re-raises revocation refusals that are not about expiry" do
      profile = AcmeWire::LETS_ENCRYPT
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "urn:ietf:params:acme:error:unauthorized", detail: "The key ID specified in the revocation request does not hold sufficient authorization"),
        status: 403)

      expect { fresh_prog.destroy }.to raise_error(Acme::Client::Error::Unauthorized)
      expect(cert).to exist
    end

    it "revokes a legacy ZeroSSL certificate against the pinned ZeroSSL directory" do
      profile = AcmeWire::ZEROSSL
      prepare_revocable_cert(profile, shared: false)
      stub_request(:post, profile.revoke_url).to_return(status: 200, headers: acme_headers, body: "")

      expect { fresh_prog.destroy }.to exit({"msg" => "certificate revoked and destroyed"})

      expect(WebMock).to have_requested(:post, profile.revoke_url).once
      expect(cert).not_to exist
    end
  end
end
