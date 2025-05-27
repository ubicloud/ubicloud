# frozen_string_literal: true

RSpec.describe Prog::Vnet::CertNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) { Strand.new }
  let(:project) {
    Project.create_with_id(name: "test-prj")
  }
  let(:dns_zone) {
    DnsZone.create_with_id(name: "test-dns-zone", project_id: project.id)
  }
  let(:cert) {
    described_class.assemble("cert-hostname", dns_zone.id).subject
  }

  before do
    allow(nx).to receive(:cert).and_return(cert)
  end

  describe ".assemble" do
    it "creates a new certificate" do
      st = described_class.assemble("test-hostname", dns_zone.id)
      expect(Cert[st.id].hostname).to eq "test-hostname"
      expect(st.label).to eq "start"
    end

    it "fails if dns_zone is not valid" do
      id = SecureRandom.uuid
      expect {
        described_class.assemble("test-hostname", id)
      }.to raise_error RuntimeError, "Given DNS zone doesn't exist with the id #{id}"
    end
  end

  describe "#before_run" do
    it "hops to destroy when needed" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx).to receive(:strand).and_return(Strand.new(label: "destroy"))
      expect { nx.before_run }.not_to hop
    end
  end

  describe "#start" do
    let(:order) {
      dns_challenge = instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name", record_type: "test-record-type", record_content: "test-record-content")
      authorization = instance_double(Acme::Client::Resources::Authorization, dns: dns_challenge)
      instance_double(Acme::Client::Resources::Order, authorizations: [authorization], url: "test-order-url")
    }

    it "registers a deadline and starts the certificate creation process" do
      client = instance_double(Acme::Client)
      key = Clec::Cert.ec_key
      expect(OpenSSL::PKey::EC).to receive(:generate).with("prime256v1").and_return(key)
      expect(Acme::Client).to receive(:new).with(private_key: key, directory: Config.acme_directory).and_return(client)
      expect(client).to receive(:new_account).with(contact: "mailto:#{Config.acme_email}", terms_of_service_agreed: true, external_account_binding: {kid: Config.acme_eab_kid, hmac_key: Config.acme_eab_hmac_key}).and_return(instance_double(Acme::Client::Resources::Account, kid: "test-kid"))
      expect(client).to receive(:new_order).with(identifiers: [cert.hostname]).and_return(order)
      expect(cert).to receive(:update).with(kid: "test-kid", account_key: key.to_der, order_url: "test-order-url")
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name"))
      expect(dns_zone).to receive(:insert_record).with(record_name: "test-record-name.cert-hostname", type: "test-record-type", ttl: 600, data: "test-record-content")

      expect { nx.start }.to hop("wait_dns_update")
    end

    it "creates a self-signed certificate in development environments without dns" do
      expect(Config).to receive(:development?).and_return(true)
      expect(cert).to receive(:dns_zone_id).and_return(nil)

      expect { nx.start }.to hop("wait")
    end
  end

  describe "#wait_dns_update" do
    it "waits for dns_record to be seen by all servers" do
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name", record_content: "content")).at_least(:once)
      dns_record = instance_double(DnsRecord, id: SecureRandom.uuid)
      expect(DnsRecord).to receive(:[]).with(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", tombstoned: false, data: "content").and_return(dns_record)
      expect { nx.wait_dns_update }.to nap(10)
    end

    it "requests validation when dns_record is seen by all servers" do
      challenge = instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name", record_content: "content")
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(nx).to receive(:dns_challenge).and_return(challenge).at_least(:once)
      dns_record = DnsRecord.create_with_id(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "test-record-type", ttl: 600, data: "content")
      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: dns_record.id, dns_server_id: nil)

      expect(challenge).to receive(:request_validation)
      expect { nx.wait_dns_update }.to hop("wait_dns_validation")
    end
  end

  describe "#wait_dns_validation" do
    let(:challenge) {
      instance_double(Acme::Client::Resources::Challenges::DNS01, status: "pending", record_name: "test-record-name", record_content: "content")
    }

    before do
      expect(nx).to receive(:dns_challenge).and_return(challenge).at_least(:once)
    end

    it "waits for dns_challenge to be validated" do
      expect { nx.wait_dns_validation }.to nap(10)
    end

    it "hops to restart if dns_challenge validation fails" do
      expect(challenge).to receive(:status).and_return("failed")
      expect(Clog).to receive(:emit).with("DNS validation failed").and_call_original
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect { nx.wait_dns_validation }.to hop("restart")
    end

    it "hops to cert_finalization when dns_challenge is valid" do
      expect(challenge).to receive(:status).and_return("valid")

      key = Clec::Cert.ec_key
      expect(OpenSSL::PKey::EC).to receive(:generate).and_return(key)
      expect(cert).to receive(:update).with(csr_key: key.to_der)
      expect { nx.wait_dns_validation }.to hop("cert_finalization")
    end
  end

  describe "#cert_finalization" do
    it "finalizes the certificate" do
      csr = instance_double(Acme::Client::CertificateRequest)
      acme_order = instance_double(Acme::Client::Resources::Order)
      expect(nx).to receive(:acme_order).and_return(acme_order).at_least(:once)
      ec = instance_double(OpenSSL::PKey::EC)
      expect(cert).to receive(:csr_key).and_return("der_key")
      expect(OpenSSL::PKey::EC).to receive(:new).with("der_key").and_return(ec)
      expect(Acme::Client::CertificateRequest).to receive(:new).with(private_key: ec, common_name: "cert-hostname").and_return(csr)
      expect(acme_order).to receive(:finalize).with(csr: csr)
      expect { nx.cert_finalization }.to hop("wait_cert_finalization")
    end
  end

  describe "#wait_cert_finalization" do
    let(:acme_order) {
      instance_double(Acme::Client::Resources::Order, status: "processing")
    }

    before do
      expect(nx).to receive(:acme_order).and_return(acme_order).at_least(:once)
    end

    it "waits for certificate to be finalized" do
      expect { nx.wait_cert_finalization }.to nap(10)
    end

    it "hops to restart if certificate finalization fails" do
      challenge = instance_double(Acme::Client::Resources::Challenges::DNS01, status: "pending", record_name: "test-record-name", record_content: "content")
      expect(nx).to receive(:dns_challenge).and_return(challenge).at_least(:once)
      expect(acme_order).to receive(:status).and_return("failed")
      expect(Clog).to receive(:emit).with("Certificate finalization failed").and_call_original
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect { nx.wait_cert_finalization }.to hop("restart")
    end

    it "updates the certificate when certificate is valid" do
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name"))
      expect(acme_order).to receive(:status).and_return("valid")
      expect(acme_order).to receive(:certificate).and_return("test-certificate")
      expect(Time).to receive(:now).and_return(Time.new(2021, 1, 1, 0, 0, 0))
      expect(cert).to receive(:update).with(cert: "test-certificate", created_at: Time.new(2021, 1, 1, 0, 0, 0))
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")
      expect { nx.wait_cert_finalization }.to hop("wait")
    end
  end

  describe "#wait" do
    it "waits for 1 month" do
      expect(cert).to receive(:created_at).and_return(Time.new(2021, 4, 1, 0, 0, 0))
      expect(Time).to receive(:now).and_return(Time.new(2021, 4, 1, 0, 0, 0))
      expect { nx.wait }.to nap(60 * 60 * 24 * 30 * 1)
    end

    it "destroys the certificate after 3 months" do
      created_at = Time.new(2021, 1, 1, 0, 0, 0)
      expect(cert).to receive(:created_at).and_return(created_at)
      expect(Time).to receive(:now).and_return(created_at + 60 * 60 * 24 * 30 * 3 + 1)
      expect(cert).to receive(:incr_destroy)
      expect { nx.wait }.to nap(0)
    end
  end

  describe "#restart" do
    it "increments the restart counter and naps according to the restart counter" do
      nx.strand.stack.first["restarted"] = 3

      expect { nx.restart }.to nap(60 * 4)
    end

    it "naps at most 10 minutes" do
      nx.strand.stack.first["restarted"] = 20

      expect { nx.restart }.to nap(60 * 10)
    end

    it "hops to start if restarted semaphore is set" do
      expect(nx).to receive(:when_restarted_set?).and_yield
      expect(nx).to receive(:decr_restarted)
      expect(nx).to receive(:update_stack_restart_counter)
      expect { nx.restart }.to hop("start")
    end
  end

  describe "#destroy" do
    it "revokes the certificate and deletes the dns record" do
      client = instance_double(Acme::Client)
      expect(cert).to receive(:cert).and_return("test-cert").at_least(:once)
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name")).at_least(:once)
      expect(nx).to receive(:acme_client).and_return(client)
      expect(client).to receive(:revoke).with(certificate: "test-cert", reason: "cessationOfOperation")
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
    end

    it "does not revoke the certificate if it doesn't exist" do
      expect(cert).to receive(:cert).and_return(nil)
      expect(nx).not_to receive(:acme_client)
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name")).at_least(:once)

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
    end

    it "skips deleting the dns record if dns_challenge doesn't exist" do
      expect(cert).to receive(:cert).and_return(nil)
      expect(nx).to receive(:dns_challenge).and_return(nil)

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
    end

    it "skips revocation and dns record deletion for self-signed certificates" do
      expect(Config).to receive(:development?).and_return(true)
      expect(cert).to receive(:dns_zone_id).and_return(nil)
      expect(cert).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "self-signed certificate destroyed"})
    end

    it "emits a log and continues if the cert is already revoked" do
      client = instance_double(Acme::Client)
      expect(cert).to receive(:cert).and_return("test-cert").at_least(:once)
      expect(nx).to receive(:acme_client).and_return(client)
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::AlreadyRevoked.new("already revoked"))

      expect(Clog).to receive(:emit).with("Certificate is already revoked").and_call_original
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name")).at_least(:once)
      expect(cert).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
    end

    it "emits a log and continues if the cert is not found" do
      client = instance_double(Acme::Client)
      expect(cert).to receive(:cert).and_return("test-cert").at_least(:once)
      expect(nx).to receive(:acme_client).and_return(client)
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::NotFound.new("not found"))

      expect(Clog).to receive(:emit).with("Certificate is not found").and_call_original
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name")).at_least(:once)
      expect(cert).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
    end

    it "emits a log and continues if the cert is revoked previously and we get Unauthorized" do
      client = instance_double(Acme::Client)
      expect(cert).to receive(:cert).and_return("test-cert").at_least(:once)
      expect(nx).to receive(:acme_client).and_return(client)
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::Unauthorized.new("The certificate has expired and cannot be revoked"))

      expect(Clog).to receive(:emit).with("Certificate is expired and cannot be revoked").and_call_original
      expect(nx).to receive(:dns_zone).and_return(dns_zone)
      expect(dns_zone).to receive(:delete_record).with(record_name: "test-record-name.cert-hostname")
      expect(nx).to receive(:dns_challenge).and_return(instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name")).at_least(:once)
      expect(cert).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
    end

    it "fires an exception if the cert is not authorized and the message is not about the certificate being expired" do
      client = instance_double(Acme::Client)
      expect(cert).to receive(:cert).and_return("test-cert").at_least(:once)
      expect(nx).to receive(:acme_client).and_return(client)
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::Unauthorized.new("The certificate is not authorized"))

      expect { nx.destroy }.to raise_error(Acme::Client::Error::Unauthorized)
    end
  end

  describe "#update_stack_restart_counter" do
    it "increments the restart counter" do
      strand = instance_double(Strand, stack: [{"restarted" => 3}])
      expect(nx).to receive(:strand).and_return(strand).at_least(:once)
      expect(strand).to receive(:modified!).with(:stack)
      expect(strand).to receive(:save_changes)

      nx.update_stack_restart_counter
      expect(strand.stack.first["restarted"]).to eq 4
    end
  end

  describe "#acme_client" do
    it "returns a new acme client" do
      expect(cert).to receive(:account_key).and_return("test-account-key").at_least(:once)
      expect(cert).to receive(:kid).and_return("test-kid")
      expect(OpenSSL::PKey::EC).to receive(:new).with("test-account-key").and_return("account-key")
      expect(Acme::Client).to receive(:new).with(private_key: "account-key", directory: Config.acme_directory, kid: "test-kid").and_return("client")

      expect(nx.acme_client).to eq "client"
    end

    it "returns nil if account key is not set" do
      expect(cert).to receive(:account_key).and_return(nil)

      expect(nx.acme_client).to be_nil
    end
  end

  describe "#acme_order" do
    it "returns the acme order" do
      expect(cert).to receive(:order_url).and_return("test-order-url").at_least(:once)
      client = instance_double(Acme::Client)
      expect(nx).to receive(:acme_client).and_return(client)
      expect(client).to receive(:order).with(url: "test-order-url").and_return("order")

      expect(nx.acme_order).to eq "order"
    end

    it "returns nil if order_url is nil" do
      expect(cert).to receive(:order_url).and_return(nil)
      expect(nx.acme_order).to be_nil
    end
  end

  describe "#dns_challenge" do
    it "returns the dns challenge" do
      order = instance_double(Acme::Client::Resources::Order)
      expect(nx).to receive(:acme_order).and_return(order)
      expect(order).to receive(:authorizations).and_return([instance_double(Acme::Client::Resources::Authorization, dns: "dns")])

      expect(nx.dns_challenge).to eq "dns"
    end
  end

  describe "#dns_zone" do
    it "returns the dns zone" do
      expect(DnsZone).to receive(:[]).with(cert.dns_zone_id).and_return("dns-zone")
      expect(nx.dns_zone).to eq "dns-zone"
    end

    it "returns nil if dns_zone_id is not set" do
      expect(cert).to receive(:dns_zone_id).and_return(nil)
      expect(nx.dns_zone).to be_nil
    end
  end
end
