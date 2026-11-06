# frozen_string_literal: true

require "base64"

# Wire-level ACME fixtures for WebMock, modeled on the observed and
# documented behavior of Let's Encrypt and Google Trust Services. The
# ZeroSSL profile matches only the shape of its responses. The real
# acme-client gem parses these responses, so these specs exercise CA
# differences that the instance_double-based specs cannot express.
#
# Fixture invariant: every response carries a Replay-Nonce header. The gem
# harvests nonces from all responses; without one it issues an extra HEAD
# new-nonce round trip, and error responses without one break the
# badNonce retry.
acme_wire = Module.new do
  self::DEFAULT_TOKEN = "tKzq2fVwHM0cgVFVOHUnXjBSCYnyoJ3ZAgMEmnJmnbo"

  profile = Class.new do
    attr_reader :name, :base, :directory_url, :new_nonce_url, :new_account_url,
      :new_order_url, :revoke_url, :account_url, :order_url, :authz_url,
      :challenge_url, :finalize_url, :cert_url

    def initialize(name:, base:, style:, meta:, error_extra: {})
      @name = name
      @base = base
      @style = style
      @meta = meta
      @error_extra = error_extra

      case style
      when :lets_encrypt
        @directory_url = "#{base}/directory"
        @new_nonce_url = "#{base}/acme/new-nonce"
        @new_account_url = "#{base}/acme/new-acct"
        @new_order_url = "#{base}/acme/new-order"
        @revoke_url = "#{base}/acme/revoke-cert"
        @account_url = "#{base}/acme/acct/424242"
        @order_url = "#{base}/acme/order/424242/31337"
        @authz_url = "#{base}/acme/authz-v3/900001"
        @challenge_url = "#{base}/acme/chall-v3/900001/dns01"
        @finalize_url = "#{base}/acme/finalize/424242/31337"
        @cert_url = "#{base}/acme/cert/03deadbeefcafe"
      when :gts
        @directory_url = "#{base}/directory"
        @new_nonce_url = "#{base}/new-nonce"
        @new_account_url = "#{base}/new-account"
        @new_order_url = "#{base}/new-order"
        @revoke_url = "#{base}/revoke-cert"
        @account_url = "#{base}/account/G5TNiqAfNGyiyHC6wibmCA"
        @order_url = "#{base}/order/skBMr3fh"
        @authz_url = "#{base}/authz/8FabQmDh"
        @challenge_url = "#{base}/challenge/8FabQmDh/dns-01"
        @finalize_url = "#{base}/finalize/skBMr3fh"
        @cert_url = "#{base}/certificate/skBMr3fh"
      when :zerossl
        @directory_url = base
        @new_nonce_url = "#{base}/newNonce"
        @new_account_url = "#{base}/newAccount"
        @new_order_url = "#{base}/newOrder"
        @revoke_url = "#{base}/revokeCert"
        @account_url = "#{base}/account/zs-legacy-account"
        @order_url = "#{base}/order/zs-order"
        @authz_url = "#{base}/authz/zs-authz"
        @challenge_url = "#{base}/chall/zs-chall"
        @finalize_url = "#{base}/finalize/zs-order"
        @cert_url = "#{base}/cert/zs-cert"
      end
    end

    def directory_body
      body = {
        "newNonce" => new_nonce_url,
        "newAccount" => new_account_url,
        "newOrder" => new_order_url,
        "revokeCert" => revoke_url,
        "keyChange" => "#{base}/key-change",
        "meta" => @meta,
      }
      case @style
      when :lets_encrypt
        # Boulder always includes a random decoy entry and renewalInfo, and
        # omits newAuthz (no pre-authorization support).
        body["Ca_random-entry"] = "https://community.letsencrypt.org/t/adding-random-entries-to-the-directory/33417"
        body["renewalInfo"] = "#{base}/draft-ietf-acme-ari-03/renewalInfo"
      when :gts
        body["newAuthz"] = "#{base}/new-authz"
        body["renewalInfo"] = "#{base}/renewal-info"
      end
      body
    end

    # GTS appends a nonstandard requestID field to problem documents; the
    # gem tolerates additive fields.
    def error_body(type:, detail:, **extra)
      {"type" => type, "detail" => detail}.merge(@error_extra).merge(extra)
    end
  end

  self::LETS_ENCRYPT = profile.new(
    name: "Let's Encrypt", base: "https://acme-v02.api.letsencrypt.org", style: :lets_encrypt,
    meta: {
      "caaIdentities" => ["letsencrypt.org"],
      "termsOfService" => "https://letsencrypt.org/documents/LE-SA-v1.5-February-24-2025.pdf",
      "website" => "https://letsencrypt.org",
    },
  )

  self::GTS = profile.new(
    name: "Google Trust Services", base: "https://dv.acme-v02.api.pki.goog", style: :gts,
    meta: {
      "termsOfService" => "https://pki.goog/GTS-SA.pdf",
      "website" => "https://pki.goog",
      "caaIdentities" => ["pki.goog"],
      "externalAccountRequired" => true,
    },
    error_extra: {"requestID" => "b6HWs8NloPH9e2jDnStFeQ"},
  )

  self::ZEROSSL = profile.new(
    name: "ZeroSSL", base: "https://acme.zerossl.com/v2/DV90", style: :zerossl,
    meta: {"termsOfService" => "https://secure.trust-provider.com/repository", "externalAccountRequired" => true},
  )

  self::Helpers = Module.new do
    define_method(:default_token) { acme_wire::DEFAULT_TOKEN }

    def acme_headers(extra = {})
      {"Replay-Nonce" => "nonce-#{SecureRandom.hex(8)}", "Content-Type" => "application/json"}.merge(extra)
    end

    def stub_acme_directory(profile)
      stub_request(:get, profile.directory_url)
        .to_return(status: 200, headers: acme_headers, body: JSON.generate(profile.directory_body))
    end

    def stub_acme_nonce(profile)
      stub_request(:head, profile.new_nonce_url)
        .to_return(status: 204, headers: {"Replay-Nonce" => "head-nonce-#{SecureRandom.hex(4)}"})
    end

    def stub_acme_json(method, url, body, status: 200, headers: {})
      stub_request(method, url)
        .to_return(status:, headers: acme_headers(headers), body: JSON.generate(body))
    end

    def acme_order_body(profile, status:, identifiers:, certificate: nil)
      body = {
        "status" => status,
        "expires" => (Time.now + 7 * 86400).utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "identifiers" => identifiers.map { {"type" => "dns", "value" => it} },
        "authorizations" => [profile.authz_url],
        "finalize" => profile.finalize_url,
      }
      body["certificate"] = certificate if certificate
      body
    end

    def acme_authz_body(profile, status:, domain:, challenge_status:, wildcard: false, token: default_token, error: nil)
      dns = {"type" => "dns-01", "url" => profile.challenge_url, "status" => challenge_status, "token" => token}
      dns["error"] = error if error
      body = {
        "identifier" => {"type" => "dns", "value" => domain},
        "status" => status,
        "expires" => (Time.now + 7 * 86400).utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "challenges" => [
          dns,
          {"type" => "http-01", "url" => "#{profile.challenge_url}-http", "status" => challenge_status, "token" => token},
        ],
      }
      body["wildcard"] = true if wildcard
      body
    end

    def decode_jws(request)
      jws = JSON.parse(request.body)
      protected_header = JSON.parse(b64u_decode(jws["protected"]))
      payload = jws["payload"].empty? ? nil : JSON.parse(b64u_decode(jws["payload"]))
      [protected_header, payload, jws]
    end

    def b64u_decode(string)
      Base64.urlsafe_decode64(string + "=" * ((4 - string.length % 4) % 4))
    end

    def expected_txt_content(private_key, token: default_token)
      thumbprint = Acme::Client::JWK.from_private_key(private_key).thumbprint
      Base64.urlsafe_encode64(OpenSSL::Digest.digest("SHA256", "#{token}.#{thumbprint}")).delete("=")
    end

    # Two PEM blocks (leaf + intermediate): the chain shape both CAs serve.
    def acme_pem_chain(common_name)
      [common_name, "Fixture Intermediate CA"].map { |cn|
        key = OpenSSL::PKey::EC.generate("prime256v1")
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = SecureRandom.random_number(2**64)
        cert.subject = cert.issuer = OpenSSL::X509::Name.new([["CN", cn]])
        cert.public_key = key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        cert.to_pem
      }.join
    end
  end
end

# Wire-level CA behavior: WebMock returns complete ACME HTTP responses
# and the real acme-client gem parses them. Examples marked "STAGING"
# rest on fixtures inferred from documentation; verify them against
# dv.acme-v02.test-api.pki.goog before enabling Google Trust Services in
# production.
RSpec.describe Prog::Vnet::CertNexus do
  include acme_wire::Helpers

  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-prj") }
  let(:dns_zone) { DnsZone.create(name: "test-dns-zone.com", project_id: project.id) }
  let(:hostname) { "cert-hostname.test-dns-zone.com" }
  let(:st) { described_class.assemble(hostname, dns_zone.id) }
  let(:cert) { st.subject }
  let(:account_key) { OpenSSL::PKey::EC.generate("prime256v1") }

  # A shared-account provider, already registered as profile.account_url
  # with account_key.
  def wire_provider(profile, name: "wire-#{profile.name}", priority: 2)
    AcmeProvider.create(
      name:,
      directory_url: profile.directory_url,
      email: "ops@example.com",
      kid: profile.account_url,
      key: account_key.to_der,
      priority:,
    )
  end

  # A provider that registers a new account per certificate, using EAB.
  def per_cert_wire_provider(profile, eab_kid:, eab_hmac_key:)
    AcmeProvider.create(
      name: "wire-#{profile.name}",
      directory_url: profile.directory_url,
      email: "ops@example.com",
      kid: eab_kid,
      key: eab_hmac_key,
      per_cert_accounts: true,
      priority: 1,
    )
  end

  def stub_pending_order(profile)
    stub_acme_json(:post, profile.new_order_url,
      acme_order_body(profile, status: "pending", identifiers: [hostname]), status: 201, headers: {"Location" => profile.order_url})
    stub_acme_json(:post, profile.authz_url, acme_authz_body(profile, status: "pending", domain: hostname, challenge_status: "pending"))
  end

  def fresh_prog
    described_class.new(st)
  end

  describe "per-certificate account registration over the wire" do
    let(:eab_hmac_secret) { SecureRandom.bytes(32) }
    let(:eab_hmac_key) { Base64.urlsafe_encode64(eab_hmac_secret) }

    it "registers at GTS with a verifiable HS256 external account binding and orders with the new account" do
      profile = acme_wire::GTS
      provider = per_cert_wire_provider(profile, eab_kid: "gts-eab-kid", eab_hmac_key:)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      account_request = nil
      stub_request(:post, profile.new_account_url)
        .with { |req|
          account_request = req
          true
        }
        .to_return(status: 201, headers: acme_headers("Location" => profile.account_url), body: JSON.generate({"status" => "valid"}))
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

      protected_header, payload, = decode_jws(account_request)
      expect(protected_header["alg"]).to eq "ES256"
      expect(protected_header["url"]).to eq profile.new_account_url
      expect(protected_header["jwk"]).to include("kty" => "EC", "crv" => "P-256")
      expect(protected_header).not_to have_key("kid")
      expect(protected_header["nonce"]).to match(/\A(head-)?nonce-/)
      expect(payload).to include("contact" => ["mailto:ops@example.com"], "termsOfServiceAgreed" => true)
      eab = payload.fetch("externalAccountBinding")
      inner_header = JSON.parse(b64u_decode(eab["protected"]))
      expect(inner_header).to eq({"alg" => "HS256", "typ" => "JWT", "kid" => "gts-eab-kid", "url" => profile.new_account_url})
      expect(JSON.parse(b64u_decode(eab["payload"]))).to eq protected_header["jwk"]
      expected_signature = Base64.urlsafe_encode64(
        OpenSSL::HMAC.digest("SHA256", eab_hmac_secret, "#{eab["protected"]}.#{eab["payload"]}"),
      ).delete("=")
      expect(eab["signature"]).to eq expected_signature

      order_header, = decode_jws(order_request)
      expect(order_header["kid"]).to eq profile.account_url
      expect(order_header).not_to have_key("jwk")

      cert.reload
      expect(cert.acme_provider_id).to eq provider.id
      expect(cert.kid).to eq profile.account_url
      embedded_key = Util.parse_key(cert.account_key)
      expect(Acme::Client::JWK.from_private_key(embedded_key).to_h.transform_keys(&:to_s)).to eq protected_header["jwk"]
      record = DnsRecord.first(name: "_acme-challenge.#{hostname}.", tombstoned: false)
      expect(record.data).to eq expected_txt_content(embedded_key)
    end

    it "raises Unauthorized on GTS EAB verification failure without recording an account (STAGING: consumed-secret body inferred)" do
      profile = acme_wire::GTS
      per_cert_wire_provider(profile, eab_kid: "used-kid", eab_hmac_key:)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      stub_acme_json(:post, profile.new_account_url,
        profile.error_body(type: "urn:ietf:params:acme:error:unauthorized", detail: "External Account Binding JWS verification failed"),
        status: 403)

      expect { fresh_prog.start }.to raise_error(Acme::Client::Error::Unauthorized, /verification failed/)
      expect(cert.reload.kid).to be_nil
      expect(cert.account_key).to be_nil
      expect(WebMock).not_to have_requested(:post, profile.new_order_url)
    end

    it "naps for the Retry-After time when account registration is rate limited" do
      profile = acme_wire::LETS_ENCRYPT
      per_cert_wire_provider(profile, eab_kid: "le-eab-kid", eab_hmac_key:)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      stub_acme_json(:post, profile.new_account_url,
        profile.error_body(type: "urn:ietf:params:acme:error:rateLimited", detail: "too many new registrations (10) from this IP address"),
        status: 429, headers: {"Retry-After" => "120"})

      expect { fresh_prog.start }.to nap(115..125)
      expect(cert.reload.kid).to be_nil
      expect(cert.account_key).to be_nil
      expect(WebMock).not_to have_requested(:post, profile.new_order_url)
    end

    it "retries transparently when badNonce arrives with a fresh Replay-Nonce" do
      profile = acme_wire::LETS_ENCRYPT
      per_cert_wire_provider(profile, eab_kid: "le-eab-kid", eab_hmac_key:)
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      stub_request(:post, profile.new_account_url).to_return(
        {status: 400, headers: acme_headers, body: JSON.generate(profile.error_body(type: "urn:ietf:params:acme:error:badNonce", detail: "JWS has invalid anti-replay nonce"))},
        {status: 201, headers: acme_headers("Location" => profile.account_url), body: JSON.generate({"status" => "valid"})},
      )
      stub_pending_order(profile)

      expect { fresh_prog.start }.to hop("wait_dns_update")

      expect(cert.reload.kid).to eq profile.account_url
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
      stub_acme_json(:post, profile.challenge_url, {"type" => "dns-01", "url" => profile.challenge_url, "status" => "processing", "token" => acme_wire::DEFAULT_TOKEN})

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
    let(:profile) { acme_wire::LETS_ENCRYPT }
    let(:provider) { wire_provider(profile) }

    before do
      provider
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
    end

    it_behaves_like "issues a certificate over the wire"

    it "rotates the restarted certificate onto the next enabled provider" do
      fallback_profile = acme_wire::GTS
      fallback = wire_provider(fallback_profile, name: "wire-fallback", priority: 1)
      stub_acme_directory(fallback_profile)
      stub_acme_nonce(fallback_profile)
      cert.update(acme_provider_id: provider.id)
      refresh_frame(nx, new_values: {"restarted" => 1})
      stub_pending_order(fallback_profile)

      expect { fresh_prog.start }.to hop("wait_dns_update")

      expect(cert.reload.acme_provider_id).to eq fallback.id
      expect(WebMock).not_to have_requested(:post, profile.new_order_url)
    end

    def stub_new_order_rate_limited(retry_after)
      headers = retry_after ? {"Retry-After" => retry_after} : {}
      stub_acme_json(:post, profile.new_order_url,
        profile.error_body(
          type: "urn:ietf:params:acme:error:rateLimited",
          detail: "too many new orders recently (300) for this account, retry after 2026-01-25 18:30:00 UTC",
        ), status: 429, headers:)
    end

    it "naps for the Retry-After time when polling the order is rate limited" do
      cert.update(acme_provider_id: provider.id, kid: profile.account_url, order_url: profile.order_url)
      st.update(label: "wait_cert_finalization")
      stub_acme_json(:post, profile.order_url,
        profile.error_body(type: "urn:ietf:params:acme:error:rateLimited", detail: "too many requests"),
        status: 429, headers: {"Retry-After" => "30"})
      refresh_frame(nx, new_values: {"remaining_auto_restarts" => 2})

      expect { fresh_prog.wait_cert_finalization }.to nap(25..35)
      expect(st.stack[0]["remaining_auto_restarts"]).to eq 2
    end

    it "naps for the Retry-After time on the verbatim new-order limit response when no auto restarts remain" do
      stub_new_order_rate_limited("3600")

      expect { fresh_prog.start }.to nap(3595..3605)
      expect(cert.reload.order_url).to be_nil
      expect(st.reload.label).to eq "start"
    end

    it "restarts when Retry-After is over #{described_class::RATE_LIMIT_MAX_NAP} seconds and auto restarts remain" do
      stub_new_order_rate_limited("3600")
      refresh_frame(nx, new_values: {"remaining_auto_restarts" => 2, "wait_deadline" => 100})

      expect { fresh_prog.start }.to hop("restart")
      expect(st.stack[0]["remaining_auto_restarts"]).to eq 1
      expect(st.stack[0]["deadline_target"]).to eq "wait"
      expect(Time.new(st.stack[0]["deadline_at"])).to be_within(10).of(Time.now + 100)
      expect(cert.reload.order_url).to be_nil
    end

    it "naps instead of restarting when Retry-After is #{described_class::RATE_LIMIT_MAX_NAP} seconds" do
      stub_new_order_rate_limited(described_class::RATE_LIMIT_MAX_NAP.to_s)
      refresh_frame(nx, new_values: {"remaining_auto_restarts" => 2})

      expect { fresh_prog.start }.to nap((described_class::RATE_LIMIT_MAX_NAP - 5)..(described_class::RATE_LIMIT_MAX_NAP + 5))
      expect(st.reload.stack[0]["remaining_auto_restarts"]).to eq 2
    end

    it "naps for acme-client's default time when the rate limit response has no Retry-After" do
      stub_new_order_rate_limited(nil)
      refresh_frame(nx, new_values: {"remaining_auto_restarts" => 2})

      expect { fresh_prog.start }.to nap(Acme::Client::Error::RateLimited::DEFAULT_RETRY_SECONDS)
      expect(st.reload.stack[0]["remaining_auto_restarts"]).to eq 2
    end
  end

  describe "issuance against Google Trust Services fixtures" do
    let(:profile) { acme_wire::GTS }
    let(:provider) { wire_provider(profile) }

    before do
      provider
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
    end

    it_behaves_like "issues a certificate over the wire"

    it "naps for the Retry-After time when quota exhaustion uses the standard problem type, even if auto restarts remain" do
      stub_acme_json(:post, profile.new_order_url,
        profile.error_body(type: "urn:ietf:params:acme:error:rateLimited", detail: "Quota exceeded for new-order requests"),
        status: 429, headers: {"Retry-After" => "60"})
      refresh_frame(nx, new_values: {"remaining_auto_restarts" => 2})

      expect { fresh_prog.start }.to nap(55..65)
      expect(st.reload.stack[0]["remaining_auto_restarts"]).to eq 2
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
    def prepare_revocable_cert(profile, legacy: false)
      pem = acme_pem_chain(hostname)
      if legacy
        # Issued before AcmeProvider existed: no provider, embedded account key.
        expect(Config).to receive(:acme_directory).and_return(profile.directory_url)
        cert.update(kid: profile.account_url, account_key: account_key.to_der, cert: pem)
      else
        provider = wire_provider(profile)
        cert.update(acme_provider_id: provider.id, kid: profile.account_url, cert: pem)
      end
      stub_acme_directory(profile)
      stub_acme_nonce(profile)
      pem
    end

    it "revokes with reason cessationOfOperation via the shared account and destroys the cert" do
      profile = acme_wire::LETS_ENCRYPT
      pem = prepare_revocable_cert(profile)
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
      profile = acme_wire::LETS_ENCRYPT
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "urn:ietf:params:acme:error:alreadyRevoked", detail: "Certificate has already been revoked"), status: 400)

      expect { fresh_prog.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "continues on Let's Encrypt's current expired-certificate response" do
      profile = acme_wire::LETS_ENCRYPT
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
      profile = acme_wire::GTS
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "type.googleapis.com/google.rpc.FailedPrecondition", detail: "Certificate has expired"),
        status: 403)

      expect { fresh_prog.destroy }.to raise_error Acme::Client::Error
      expect(cert).to exist
    end

    it "naps for the Retry-After time without restarting when revocation is rate limited" do
      profile = acme_wire::LETS_ENCRYPT
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "urn:ietf:params:acme:error:rateLimited", detail: "too many revocation requests"),
        status: 429, headers: {"Retry-After" => "3600"})
      refresh_frame(nx, new_values: {"remaining_auto_restarts" => 2})

      expect { fresh_prog.destroy }.to nap(3595..3605)
      expect(st.stack[0]["remaining_auto_restarts"]).to eq 2
      expect(cert).to exist
    end

    it "re-raises revocation refusals that are not about expiry" do
      profile = acme_wire::LETS_ENCRYPT
      prepare_revocable_cert(profile)
      stub_acme_json(:post, profile.revoke_url,
        profile.error_body(type: "urn:ietf:params:acme:error:unauthorized", detail: "The key ID specified in the revocation request does not hold sufficient authorization"),
        status: 403)

      expect { fresh_prog.destroy }.to raise_error(Acme::Client::Error::Unauthorized)
      expect(cert).to exist
    end

    it "revokes a legacy ZeroSSL certificate with its embedded account key against the configured directory" do
      profile = acme_wire::ZEROSSL
      prepare_revocable_cert(profile, legacy: true)
      stub_request(:post, profile.revoke_url).to_return(status: 200, headers: acme_headers, body: "")

      expect { fresh_prog.destroy }.to exit({"msg" => "certificate revoked and destroyed"})

      expect(WebMock).to have_requested(:post, profile.revoke_url).once
      expect(WebMock).not_to have_requested(:post, profile.new_account_url)
      expect(cert).not_to exist
    end
  end
end
