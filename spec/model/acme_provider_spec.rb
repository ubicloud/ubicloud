# frozen_string_literal: true

RSpec.describe AcmeProvider do
  describe "reconciliation" do
    it "seeds one per-certificate-account provider from the legacy variables" do
      expect(Config).to receive(:acme_providers).at_least(:once).and_return(nil)

      result = described_class.reconcile_from_config!

      provider = described_class.first(directory_url: Config.acme_directory)
      expect(result).to eq ["create #{provider.name} #{Config.acme_directory} (priority 0)"]
      expect(provider.per_cert_accounts).to be true
      expect(provider.enabled).to be true
      expect(described_class.reconcile_plan).to eq []
    end

    it "plans without writing, applies, and converges to an empty plan" do
      stale = described_class.create(name: "dv.acme-v02.api.pki.goog", directory_url: "https://dv.acme-v02.api.pki.goog/directory",
        priority: 9, enabled: false, eab_kid: "stale-kid", eab_hmac_key: "stale-hmac")
      removed = described_class.create(name: "gone", directory_url: "https://gone.example/d", priority: 5)
      expect(Config).to receive(:acme_providers).at_least(:once).and_return(<<~JSON)
        [{"directory": "https://acme-v02.api.letsencrypt.org/directory", "email": "ops@example.com"},
         {"directory": "https://dv.acme-v02.api.pki.goog/directory", "eab_kid": "k", "eab_hmac_key": "new-hmac"}]
      JSON

      plan = described_class.reconcile_plan

      expect(plan).to eq ["create acme-v02.api.letsencrypt.org https://acme-v02.api.letsencrypt.org/directory (priority 0)",
        "update dv.acme-v02.api.pki.goog (eab_kid, eab_hmac_key, priority, enabled)",
        "disable gone"]
      expect(plan.join).not_to include "new-hmac"
      expect(described_class.count).to eq 2
      expect(stale.reload.eab_hmac_key).to eq "stale-hmac"
      expect(removed.reload.enabled).to be true

      expect(described_class.reconcile_from_config!).to eq plan
      expect(stale.reload.eab_hmac_key).to eq "new-hmac"
      expect(stale.enabled).to be true
      expect(stale.priority).to eq 1
      expect(removed.reload.enabled).to be false
      expect(described_class.first(directory_url: "https://acme-v02.api.letsencrypt.org/directory").contact).to eq "mailto:ops@example.com"

      expect(described_class.reconcile_plan).to eq []
    end

    it "converges by updating when losing a concurrent seeding race" do
      winner = described_class.create(name: "raced.example", directory_url: "https://raced.example/d", priority: 0)
      expect(Config).to receive(:acme_providers).at_least(:once).and_return('[{"directory": "https://raced.example/d", "email": "ops@example.com"}]')
      # Hide the winner from the snapshot to force the create path, then
      # fail the insert with real SQL so the transaction aborts exactly
      # the way a genuine concurrent seeding race aborts it.
      expect(described_class).to receive(:reconcile_snapshot).and_return([])
      expect(described_class).to receive(:create) do |**|
        described_class.dataset.insert(id: winner.id, name: "raced.example", directory_url: "https://raced.example/d", priority: 0)
      end

      described_class.reconcile_from_config!

      expect(described_class.first(directory_url: "https://raced.example/d").email).to eq "ops@example.com"
    end

    it "re-raises when the failed create is not a seeding race" do
      expect(Config).to receive(:acme_providers).at_least(:once).and_return('[{"directory": "https://ghost.example/d"}]')
      expect(described_class).to receive(:create).and_raise(Sequel::UniqueConstraintViolation, "duplicate key")

      expect { described_class.reconcile_from_config! }.to raise_error Sequel::UniqueConstraintViolation
      expect(described_class.first(directory_url: "https://ghost.example/d")).to be_nil
    end

    it "surfaces a name collision across directories and applies nothing" do
      expect(Config).to receive(:acme_providers).at_least(:once).and_return(<<~JSON)
        [{"directory": "https://one.example/d", "name": "shared-name"},
         {"directory": "https://two.example/d", "name": "shared-name"}]
      JSON

      expect { described_class.reconcile_from_config! }.to raise_error Sequel::ValidationFailed, /name/
      expect(described_class.where(directory_url: ["https://one.example/d", "https://two.example/d"])).to be_empty
    end

    it "requires a directory in every entry" do
      expect(Config).to receive(:acme_providers).and_return('[{"email": "x@example.com"}]')
      expect { described_class.reconcile_from_config! }.to raise_error RuntimeError, /require a directory/
    end

    it "rejects configuration that is not an array of objects with known, well-typed keys" do
      {
        '{"directory": "https://a.example/d"}' => "ACME_PROVIDERS must be a JSON array",
        '["https://a.example/d"]' => "ACME_PROVIDERS entries must be JSON objects",
        '[{"directory": "https://a.example/d", "bogus": true}]' => 'ACME_PROVIDERS entries take no "bogus" key',
        '[{"directory": 7}]' => 'ACME_PROVIDERS key "directory" must be a string',
        '[{"directory": "https://a.example/d", "priority": "1"}]' => 'ACME_PROVIDERS key "priority" must be an integer',
        '[{"directory": "https://a.example/d", "enabled": "false"}]' => 'ACME_PROVIDERS key "enabled" must be true or false',
      }.each do |json, message|
        expect(Config).to receive(:acme_providers).and_return(json)
        expect { described_class.reconcile_plan }.to raise_error RuntimeError, message
      end
    end

    it "accepts every documented key" do
      expect(Config).to receive(:acme_providers).at_least(:once).and_return(<<~JSON)
        [{"directory": "https://a.example/d", "name": "a", "email": "ops@example.com", "eab_kid": "k",
          "eab_hmac_key": "h", "per_cert_accounts": true, "priority": 3, "enabled": false, "evacuate": false}]
      JSON

      expect(described_class.reconcile_plan).to eq ["create a https://a.example/d (priority 3)"]
    end

    it "rejects an empty provider list" do
      expect(Config).to receive(:acme_providers).and_return("[]")
      expect { described_class.reconcile_from_config! }.to raise_error RuntimeError, /at least one provider/
    end
  end

  describe ".backfill_legacy_cert_pins" do
    it "fails without a provider row matching the legacy directory" do
      expect {
        described_class.backfill_legacy_cert_pins
      }.to raise_error RuntimeError, /run AcmeProvider.reconcile_from_config! first/
    end

    it "pins only registered embedded-key certificates and reports each run" do
      provider = described_class.create(name: "legacy", directory_url: Config.acme_directory, priority: 0, per_cert_accounts: true)
      project = Project.create(name: "p")
      dns_zone = DnsZone.create(name: "z.com", project_id: project.id)
      first_cert, second_cert = ["h.z.com", "h2.z.com"].map do |hostname|
        cert = Prog::Vnet::CertNexus.assemble(hostname, dns_zone.id).subject
        cert.update(kid: "legacy-#{hostname}", account_key: Clec::Cert.ec_key.to_der)
        cert
      end
      dev_cert = Prog::Vnet::CertNexus.assemble("dev.z.com", dns_zone.id).subject

      expect(described_class.backfill_legacy_cert_pins).to eq "pinned 2 certificates"
      expect(first_cert.reload.acme_provider_id).to eq provider.id
      expect(second_cert.reload.acme_provider_id).to eq provider.id
      expect(dev_cert.reload.acme_provider_id).to be_nil

      straggler = Prog::Vnet::CertNexus.assemble("late.z.com", dns_zone.id).subject
      straggler.update(kid: "legacy-late", account_key: Clec::Cert.ec_key.to_der)
      expect(described_class.backfill_legacy_cert_pins).to eq "pinned 1 certificate"
      expect(straggler.reload.acme_provider_id).to eq provider.id

      expect(described_class.backfill_legacy_cert_pins).to eq "pinned 0 certificates"
    end
  end

  describe ".for_attempt" do
    let(:fresh_cert) { instance_double(Cert, acme_provider_id: nil) }

    it "selects enabled providers in priority order and rotates by attempt" do
      described_class.create(name: "b", directory_url: "https://b.example/d", priority: 1)
      described_class.create(name: "a", directory_url: "https://a.example/d", priority: 0)
      described_class.create(name: "off", directory_url: "https://off.example/d", priority: 0, enabled: false)

      expect(described_class.for_attempt(fresh_cert, 0).name).to eq "a"
      expect(described_class.for_attempt(fresh_cert, 1).name).to eq "b"
      expect(described_class.for_attempt(fresh_cert, 2).name).to eq "a"
    end

    it "skips the certificate's current provider after a restart when an alternative exists" do
      a = described_class.create(name: "a", directory_url: "https://a.example/d", priority: 0)
      described_class.create(name: "b", directory_url: "https://b.example/d", priority: 1)
      pinned = instance_double(Cert, acme_provider_id: a.id)

      expect(described_class.for_attempt(pinned, 0).name).to eq "a"
      expect(described_class.for_attempt(pinned, 2).name).to eq "b"
    end

    it "does not skip when the current provider is the only candidate" do
      a = described_class.create(name: "a", directory_url: "https://a.example/d", priority: 0)
      pinned = instance_double(Cert, acme_provider_id: a.id)

      expect(described_class.for_attempt(pinned, 3).name).to eq "a"
    end

    it "fails with console guidance when no provider is enabled" do
      described_class.create(name: "off", directory_url: "https://off.example/d", priority: 0, enabled: false)
      expect {
        described_class.for_attempt(fresh_cert, 0)
      }.to raise_error RuntimeError, /run AcmeProvider.reconcile_from_config! from a console/
    end
  end

  describe "#evacuate!" do
    it "disables the provider and requests reissue of its issued certificates" do
      provider = described_class.create(name: "sick", directory_url: "https://sick.example/d", priority: 0)
      project = Project.create(name: "p")
      dns_zone = DnsZone.create(name: "z.com", project_id: project.id)
      issued = Prog::Vnet::CertNexus.assemble("issued.z.com", dns_zone.id).subject
      issued.update(acme_provider_id: provider.id, cert: "pem", created_at: Time.now)
      in_flight = Prog::Vnet::CertNexus.assemble("inflight.z.com", dns_zone.id).subject
      in_flight.update(acme_provider_id: provider.id)
      in_flight.strand.update(label: "wait_dns_validation")
      starting = Prog::Vnet::CertNexus.assemble("starting.z.com", dns_zone.id).subject
      starting.update(acme_provider_id: provider.id)
      expect(Cert.fresh.where(id: issued.id).count).to eq 1
      expect(Cert).to receive(:request_replacement).with([issued.id]).and_call_original

      provider.evacuate!

      expect(provider.reload.enabled).to be false
      expect(issued.reload.reissue_requested_at).not_to be_nil
      expect(in_flight.reload.reissue_requested_at).to be_nil
      expect(Cert.fresh.where(id: issued.id).count).to eq 0
      expect(in_flight.restarted_set?).to be true
      expect(starting.restarted_set?).to be false
      expect(issued.restarted_set?).to be false
    end

    it "stamps only certificates that are not already requested for reissue" do
      provider = described_class.create(name: "sick", directory_url: "https://sick.example/d", priority: 0)
      project = Project.create(name: "p")
      dns_zone = DnsZone.create(name: "z.com", project_id: project.id)
      issued = Prog::Vnet::CertNexus.assemble("issued.z.com", dns_zone.id).subject
      issued.update(acme_provider_id: provider.id, cert: "pem")

      provider.evacuate!
      first_stamp = issued.reload.reissue_requested_at
      provider.evacuate!

      expect(issued.reload.reissue_requested_at).to eq first_stamp
    end

    it "drains providers flagged evacuate and re-plans only when there is work" do
      provider = described_class.create(name: "dv.acme-v02.api.pki.goog", directory_url: "https://dv.acme-v02.api.pki.goog/directory", priority: 0)
      project = Project.create(name: "p")
      dns_zone = DnsZone.create(name: "z.com", project_id: project.id)
      issued = Prog::Vnet::CertNexus.assemble("issued.z.com", dns_zone.id).subject
      issued.update(acme_provider_id: provider.id, cert: "pem")
      expect(Config).to receive(:acme_providers).at_least(:once).and_return(<<~JSON)
        [{"directory": "https://acme-v02.api.letsencrypt.org/directory"},
         {"directory": "https://dv.acme-v02.api.pki.goog/directory", "evacuate": true}]
      JSON

      first_run = described_class.reconcile_from_config!
      expect(first_run).to include "evacuate dv.acme-v02.api.pki.goog"
      expect(first_run.grep(/update.*enabled/)).to be_empty
      first_stamp = issued.reload.reissue_requested_at
      expect(first_stamp).not_to be_nil
      expect(provider.reload.enabled).to be false

      expect(described_class.reconcile_plan).to eq []
      expect(issued.reload.reissue_requested_at).to eq first_stamp

      straggler = Prog::Vnet::CertNexus.assemble("late.z.com", dns_zone.id).subject
      straggler.update(acme_provider_id: provider.id, cert: "pem")
      expect(described_class.reconcile_from_config!).to eq ["evacuate dv.acme-v02.api.pki.goog"]
      expect(straggler.reload.reissue_requested_at).not_to be_nil
      expect(issued.reload.reissue_requested_at).to eq first_stamp
    end

    it "creates a flagged provider disabled by evacuating it immediately" do
      expect(Config).to receive(:acme_providers).at_least(:once).and_return(<<~JSON)
        [{"directory": "https://acme-v02.api.letsencrypt.org/directory"},
         {"directory": "https://born-bad.example/d", "evacuate": true}]
      JSON

      result = described_class.reconcile_from_config!

      expect(result).to include "evacuate born-bad.example"
      expect(described_class.first(directory_url: "https://born-bad.example/d").enabled).to be false
    end
  end

  describe "#issuance_identity" do
    it "uses the shared account for shared-account providers" do
      provider = described_class.create(name: "shared", directory_url: "https://s.example/d", priority: 0)
      key = Clec::Cert.ec_key
      AcmeAccount.create(acme_provider_id: provider.id, account_key: key.to_der, kid: "shared-kid")

      private_key, kid, embedded = provider.issuance_identity
      expect(private_key.to_der).to eq key.to_der
      expect(kid).to eq "shared-kid"
      expect(embedded).to be_nil
    end

    it "registers a fresh embedded account for per_cert_accounts providers" do
      provider = described_class.create(name: "legacy", directory_url: "https://l.example/d", priority: 0, per_cert_accounts: true)
      expect(provider).to receive(:register_account).with(kind_of(OpenSSL::PKey::EC)).and_return("fresh-kid")

      private_key, kid, embedded = provider.issuance_identity
      expect(kid).to eq "fresh-kid"
      expect(embedded).to eq private_key.to_der
      expect(AcmeAccount.where(acme_provider_id: provider.id)).to be_empty
    end
  end

  describe "#register_account" do
    it "registers with the provider's contact and external account binding" do
      provider = described_class.create(name: "ca", directory_url: "https://ca.example/d", priority: 0,
        email: "ops@example.com", eab_kid: "k", eab_hmac_key: "h")
      key = Clec::Cert.ec_key
      acme = instance_double(Acme::Client)
      expect(Acme::Client).to receive(:new).with(private_key: key, directory: "https://ca.example/d", **described_class::CLIENT_OPTIONS).and_return(acme)
      expect(acme).to receive(:new_account).with(contact: "mailto:ops@example.com", terms_of_service_agreed: true, external_account_binding: {kid: "k", hmac_key: "h"}).and_return(instance_double(Acme::Client::Resources::Account, kid: "new-kid"))

      expect(provider.register_account(key)).to eq "new-kid"
    end
  end

  describe ".status" do
    it "reports an empty catalog" do
      expect(described_class.status).to eq []
    end

    it "summarizes each provider's catalog and runtime state" do
      provider = described_class.create(name: "zerossl", directory_url: Config.acme_directory, priority: 0, per_cert_accounts: true)
      AcmeAccount.create(acme_provider_id: provider.id, account_key: Clec::Cert.ec_key.to_der, kid: "shared-kid")
      project = Project.create(name: "p")
      dns_zone = DnsZone.create(name: "z.com", project_id: project.id)
      issued = Prog::Vnet::CertNexus.assemble("issued.z.com", dns_zone.id).subject
      issued.update(acme_provider_id: provider.id, cert: "pem", reissue_requested_at: Time.now)
      Prog::Vnet::CertNexus.assemble("pending.z.com", dns_zone.id).subject.update(acme_provider_id: provider.id)

      expect(described_class.status).to eq [{name: "zerossl", enabled: true, priority: 0,
                                             account_kid: "shared-kid", issued_certs: 1, awaiting_reissue: 1}]
    end
  end

  describe ".status", "without a shared account" do
    it "reports no account kid" do
      described_class.create(name: "per-cert", directory_url: "https://per-cert.example/d", priority: 0, per_cert_accounts: true)

      expect(described_class.status).to eq [{name: "per-cert", enabled: true, priority: 0,
                                             account_kid: nil, issued_certs: 0, awaiting_reissue: 0}]
    end
  end

  describe "helpers" do
    it "builds contact and external account binding only from present fields" do
      bare = described_class.create(name: "bare", directory_url: "https://bare.example/d", priority: 0)
      expect(bare.contact).to be_nil
      expect(bare.external_account_binding).to be_nil

      full = described_class.create(name: "full", directory_url: "https://full.example/d", priority: 1,
        email: "ops@example.com", eab_kid: "kid", eab_hmac_key: "hmac")
      expect(full.contact).to eq "mailto:ops@example.com"
      expect(full.external_account_binding).to eq({kid: "kid", hmac_key: "hmac"})
    end
  end

  describe "constraints" do
    it "rejects duplicate directory urls" do
      described_class.create(name: "a", directory_url: "https://dup.example/d", priority: 0)
      expect {
        described_class.create(name: "b", directory_url: "https://dup.example/d", priority: 1)
      }.to raise_error Sequel::ValidationFailed, /directory_url is already taken/
    end
  end
end
