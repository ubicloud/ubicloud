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
module AcmeWire
  DEFAULT_TOKEN = "tKzq2fVwHM0cgVFVOHUnXjBSCYnyoJ3ZAgMEmnJmnbo"

  class Profile
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

  LETS_ENCRYPT = Profile.new(
    name: "Let's Encrypt", base: "https://acme-v02.api.letsencrypt.org", style: :lets_encrypt,
    meta: {
      "caaIdentities" => ["letsencrypt.org"],
      "termsOfService" => "https://letsencrypt.org/documents/LE-SA-v1.5-February-24-2025.pdf",
      "website" => "https://letsencrypt.org",
    },
  )

  GTS = Profile.new(
    name: "Google Trust Services", base: "https://dv.acme-v02.api.pki.goog", style: :gts,
    meta: {
      "termsOfService" => "https://pki.goog/GTS-SA.pdf",
      "website" => "https://pki.goog",
      "caaIdentities" => ["pki.goog"],
      "externalAccountRequired" => true,
    },
    error_extra: {"requestID" => "b6HWs8NloPH9e2jDnStFeQ"},
  )

  ZEROSSL = Profile.new(
    name: "ZeroSSL", base: "https://acme.zerossl.com/v2/DV90", style: :zerossl,
    meta: {"termsOfService" => "https://secure.trust-provider.com/repository", "externalAccountRequired" => true},
  )

  module Helpers
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

    def acme_authz_body(profile, status:, domain:, challenge_status:, wildcard: false, token: DEFAULT_TOKEN, error: nil)
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

    def expected_txt_content(private_key, token: DEFAULT_TOKEN)
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
