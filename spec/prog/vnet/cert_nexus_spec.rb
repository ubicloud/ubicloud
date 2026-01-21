# frozen_string_literal: true

RSpec.describe Prog::Vnet::CertNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:project) {
    Project.create(name: "test-prj")
  }
  let(:dns_zone) {
    DnsZone.create(name: "test-dns-zone", project_id: project.id)
  }
  let(:st) { described_class.assemble("cert-hostname", dns_zone.id) }
  let(:cert) { st.subject }
  let(:client) { instance_double(Acme::Client) }
  let(:account_key) { Clec::Cert.ec_key }

  def setup_order(new_order: false, with_order: true, add_private: false)
    dns_challenge = instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name", record_type: "test-record-type", record_content: "test-record-content")
    # Each authorization includes a domain attribute per RFC 8555 Section 7.1.4
    authorization = instance_double(Acme::Client::Resources::Authorization, dns: dns_challenge, domain: cert.hostname)
    authorizations = [authorization]

    if add_private
      private_dns_challenge = instance_double(Acme::Client::Resources::Challenges::DNS01, record_name: "test-record-name", record_type: "test-record-type", record_content: "test-record-content-private")
      private_authorization = instance_double(Acme::Client::Resources::Authorization, dns: private_dns_challenge, domain: "private-#{cert.hostname}")
      authorizations << private_authorization
    end

    order = instance_double(Acme::Client::Resources::Order, authorizations:, url: "test-order-url") if with_order

    unless new_order
      expect(Acme::Client).to receive(:new).and_return(client)
      if with_order
        expect(client).to receive(:order).with(url: "test-order-url").and_return(order)
        cert.update(order_url: "test-order-url", account_key: account_key.to_der, kid: "x")
      else
        cert.update(account_key: account_key.to_der, kid: "x")
      end
    end

    order
  end

  def use_add_private(identifiers: [])
    st.stack = [{"restarted" => 0, "add_private" => true}]
    nx.instance_variable_set(:@frame, nil)
    identifiers << "private-#{cert.hostname}"
  end

  describe ".assemble" do
    it "creates a new certificate" do
      st = described_class.assemble("test-hostname", dns_zone.id)
      expect(st.subject.hostname).to eq "test-hostname"
      expect(st.label).to eq "start"
      expect(st.stack[0]["add_private"]).to be false
    end

    it "supports add_private argument" do
      st = described_class.assemble("test-hostname", dns_zone.id, add_private: true)
      expect(Cert[st.id].hostname).to eq "test-hostname"
      expect(st.stack[0]["add_private"]).to be true
    end

    it "fails if dns_zone is not valid" do
      id = SecureRandom.uuid
      expect {
        described_class.assemble("test-hostname", id)
      }.to raise_error RuntimeError, "Given DNS zone doesn't exist with the id #{id}"
    end
  end

  describe "#start" do
    it "registers a deadline and starts the certificate creation process" do
      identifiers = [cert.hostname]
      order = setup_order(new_order: true)
      expect(OpenSSL::PKey::EC).to receive(:generate).with("prime256v1").and_return(account_key)
      expect(Acme::Client).to receive(:new).with(private_key: account_key, directory: Config.acme_directory).and_return(client)
      expect(client).to receive(:new_account).with(contact: "mailto:#{Config.acme_email}", terms_of_service_agreed: true, external_account_binding: {kid: Config.acme_eab_kid, hmac_key: Config.acme_eab_hmac_key}).and_return(instance_double(Acme::Client::Resources::Account, kid: "test-kid"))
      expect(client).to receive(:new_order).with(identifiers:).and_return(order)

      expect { nx.start }.to hop("wait_dns_update")
      expect(cert.reload.kid).to eq("test-kid")
      expect(cert.order_url).to eq("test-order-url")
      expect(DnsRecord.where(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.").count).to eq(1)
    end

    it "registers a deadline and starts the certificate creation process when adding private DNS name" do
      identifiers = [cert.hostname]
      use_add_private(identifiers:)
      # With add_private, ACME returns two authorizations (one per domain)
      order = setup_order(new_order: true, add_private: true)
      expect(OpenSSL::PKey::EC).to receive(:generate).with("prime256v1").and_return(account_key)
      expect(Acme::Client).to receive(:new).with(private_key: account_key, directory: Config.acme_directory).and_return(client)
      expect(client).to receive(:new_account).with(contact: "mailto:#{Config.acme_email}", terms_of_service_agreed: true, external_account_binding: {kid: Config.acme_eab_kid, hmac_key: Config.acme_eab_hmac_key}).and_return(instance_double(Acme::Client::Resources::Account, kid: "test-kid"))
      expect(client).to receive(:new_order).with(identifiers:).and_return(order)

      expect { nx.start }.to hop("wait_dns_update")
      expect(cert.reload.kid).to eq("test-kid")
      expect(cert.order_url).to eq("test-order-url")
      # Each authorization creates ONE DNS record for its own domain
      expect(DnsRecord.where(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.").count).to eq(1)
      expect(DnsRecord.where(dns_zone_id: dns_zone.id, name: "test-record-name.private-cert-hostname.").count).to eq(1)
    end

    it "creates a self-signed certificate in development environments without dns" do
      expect(Config).to receive(:development?).and_return(true).at_least(:once)
      self_signed_cert = Cert.create(hostname: "self-signed-host", dns_zone_id: nil)
      self_signed_strand = Strand.create_with_id(self_signed_cert, prog: "Vnet::CertNexus", label: "start", stack: [{"restarted" => 0}])
      self_signed_nx = described_class.new(self_signed_strand)

      expect { self_signed_nx.start }.to hop("wait")
    end
  end

  describe "#wait_dns_update" do
    before do
      @order = setup_order
      @dns_record = DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "test-record-type", ttl: 600, data: "test-record-content")
    end

    it "waits for dns_record to be seen by all servers" do
      expect { nx.wait_dns_update }.to nap(10)
    end

    it "requests validation when dns_record is seen by all servers" do
      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: @dns_record.id, dns_server_id: nil)

      expect(@order.authorizations.first.dns).to receive(:request_validation)
      expect { nx.wait_dns_update }.to hop("wait_dns_validation")
      expect(st.reload.stack[0]["last_dns_validation_request"]).to be_within(10).of(Time.now.to_i)
    end
  end

  describe "#wait_dns_validation with single authorization" do
    before do
      @order = setup_order
      @challenge = @order.authorizations.first.dns
    end

    it "waits for dns_challenge to be validated if pending" do
      expect(@challenge).to receive(:status).and_return("pending")
      expect { nx.wait_dns_validation }.to nap(10)
    end

    it "waits for dns_challenge to be validated if processing" do
      expect(@challenge).to receive(:status).and_return("processing")
      expect { nx.wait_dns_validation }.to nap(10)
    end

    it "rerequests DNS validation if it has been more than 2 minutes and is still not valid" do
      expect(@challenge).to receive(:status).and_return("processing")
      expect(@challenge).to receive(:request_validation)
      refresh_frame(nx, new_values: {"last_dns_validation_request" => Time.now.to_i - 130})
      expect { nx.wait_dns_validation }.to nap(10)
      expect(st.reload.stack[0]["last_dns_validation_request"]).to be_within(10).of(Time.now.to_i)
    end

    it "hops to restart if dns_challenge validation fails" do
      expect(@challenge).to receive(:status).and_return("failed")
      expect(Clog).to receive(:emit).with("DNS validation failed", instance_of(Hash)).and_call_original
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")
      expect { nx.wait_dns_validation }.to hop("restart")
    end

    it "hops to cert_finalization when dns_challenge is valid" do
      expect(@challenge).to receive(:status).and_return("valid")

      key = Clec::Cert.ec_key
      expect(OpenSSL::PKey::EC).to receive(:generate).and_return(key)
      expect { nx.wait_dns_validation }.to hop("cert_finalization")
      expect(cert.reload.csr_key).not_to be_nil
    end
  end

  describe "#wait_dns_validation with multiple authorizations" do
    it "waits for dns_challenge to be validated if one authorization is processing and another is valid" do
      order = setup_order(add_private: true)
      challenge1, challenge2 = order.authorizations.map(&:dns)
      expect(challenge1).to receive(:status).and_return("processing")
      expect(challenge2).to receive(:status).and_return("valid")
      expect { nx.wait_dns_validation }.to nap(10)
    end

    it "hops to cert_finalization when all authorizations are valid" do
      order = setup_order(add_private: true)
      challenge1, challenge2 = order.authorizations.map(&:dns)
      expect(challenge1).to receive(:status).and_return("valid")
      expect(challenge2).to receive(:status).and_return("valid")
      key = Clec::Cert.ec_key
      expect(OpenSSL::PKey::EC).to receive(:generate).and_return(key)
      expect { nx.wait_dns_validation }.to hop("cert_finalization")
      expect(cert.reload.csr_key).not_to be_nil
    end
  end

  describe "#cert_finalization" do
    [true, false].each do |use_add_private|
      it "finalizes the certificate#{" when adding private DNS name" if use_add_private}" do
        names = []
        use_add_private(identifiers: names) if use_add_private
        csr = instance_double(Acme::Client::CertificateRequest)
        key = Clec::Cert.ec_key
        cert.update(csr_key: key.to_der)
        expect(Acme::Client::CertificateRequest).to receive(:new).with(private_key: instance_of(OpenSSL::PKey::EC), common_name: "cert-hostname", names:).and_return(csr)
        expect(setup_order).to receive(:finalize).with(csr:)
        expect { nx.cert_finalization }.to hop("wait_cert_finalization")
      end
    end
  end

  describe "#wait_cert_finalization" do
    before do
      @acme_order = setup_order
    end

    it "waits for certificate to be finalized" do
      expect(@acme_order).to receive(:status).and_return("processing")
      expect { nx.wait_cert_finalization }.to nap(10)
    end

    it "hops to restart if certificate finalization fails" do
      expect(@acme_order).to receive(:status).and_return("failed")
      expect(Clog).to receive(:emit).with("Certificate finalization failed", instance_of(Hash)).and_call_original
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")

      expect { nx.wait_cert_finalization }.to hop("restart")
        .and change { DnsRecord.where(:tombstoned).count }.from(0).to(1)
    end

    it "updates the certificate when certificate is valid" do
      expect(@acme_order).to receive(:status).and_return("valid")
      expect(@acme_order).to receive(:certificate).and_return("test-certificate")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")
      expect { nx.wait_cert_finalization }.to hop("wait")
        .and change { DnsRecord.where(:tombstoned).count }.from(0).to(1)
      expect(cert.reload.cert).to eq("test-certificate")
    end
  end

  describe "#wait_cert_finalization with add_private" do
    it "deletes both DNS records for both authorizations" do
      use_add_private(identifiers: [])
      order = setup_order(add_private: true)
      cert.update(order_url: "test-order-url", account_key: account_key.to_der, kid: "x")
      expect(order).to receive(:status).and_return("valid")
      expect(order).to receive(:certificate).and_return("test-certificate")

      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "test-record-content")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.private-cert-hostname.", type: "TXT", ttl: 600, data: "test-record-content-private")
      expect { nx.wait_cert_finalization }.to hop("wait")
        .and change { DnsRecord.where(:tombstoned).count }.from(0).to(2)
      expect(cert.reload.cert).to eq("test-certificate")
    end
  end

  describe "#wait" do
    it "waits for 1 month" do
      cert.update(created_at: Time.new(2021, 4, 1, 0, 0, 0))
      expect(Time).to receive(:now).and_return(Time.new(2021, 4, 1, 0, 0, 0))
      expect { nx.wait }.to nap(60 * 60 * 24 * 30 * 1)
    end

    it "destroys the certificate after 3 months" do
      created_at = Time.new(2021, 1, 1, 0, 0, 0)
      cert.update(created_at:)
      expect(Time).to receive(:now).and_return(created_at + 60 * 60 * 24 * 30 * 3 + 1)
      expect { nx.wait }.to nap(0)
      expect(Semaphore.where(strand_id: cert.id, name: "destroy").count).to eq(1)
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
      nx.strand.stack.first["restarted"] = 0
      expect(nx).to receive(:when_restarted_set?).and_yield
      expect(nx).to receive(:decr_restarted)
      expect(nx).to receive(:update_stack)
      expect { nx.restart }.to hop("start")
    end
  end

  describe "#destroy" do
    it "revokes the certificate and deletes the dns record" do
      setup_order
      cert.update(cert: "test-cert")
      expect(client).to receive(:revoke).with(certificate: "test-cert", reason: "cessationOfOperation")
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "does not revoke the certificate if it doesn't exist" do
      setup_order
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")
      expect(cert).to exist

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "skips deleting the dns record if dns_challenge doesn't exist" do
      setup_order
      expect(cert).to exist

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "skips deleting the dns record if acme_order doesn't exist" do
      expect(nx).to receive(:acme_order).and_return(nil)
      expect(cert).to exist

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "skips revocation and dns record deletion for self-signed certificates" do
      expect(Config).to receive(:development?).and_return(true)
      self_signed_cert = Cert.create(hostname: "self-signed-host", dns_zone_id: nil)
      self_signed_strand = Strand.create_with_id(self_signed_cert, prog: "Vnet::CertNexus", label: "destroy", stack: [{"restarted" => 0}])
      self_signed_nx = described_class.new(self_signed_strand)

      expect { self_signed_nx.destroy }.to exit({"msg" => "self-signed certificate destroyed"})
      expect(self_signed_cert).not_to exist
    end

    it "emits a log and continues if the cert is already revoked" do
      setup_order
      cert.update(cert: "test-cert")
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::AlreadyRevoked.new("already revoked"))
      expect(Clog).to receive(:emit).with("Certificate is already revoked", instance_of(Hash)).and_call_original
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "emits a log and continues if the cert is not found" do
      setup_order
      cert.update(cert: "test-cert")
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::NotFound.new("not found"))
      expect(Clog).to receive(:emit).with("Certificate is not found", instance_of(Hash)).and_call_original
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "emits a log and continues if the cert is revoked previously and we get Unauthorized" do
      setup_order
      cert.update(cert: "test-cert")
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::Unauthorized.new("The certificate has expired and cannot be revoked"))
      expect(Clog).to receive(:emit).with("Certificate is expired and cannot be revoked", instance_of(Hash)).and_call_original
      DnsRecord.create(dns_zone_id: dns_zone.id, name: "test-record-name.cert-hostname.", type: "TXT", ttl: 600, data: "content")

      expect { nx.destroy }.to exit({"msg" => "certificate revoked and destroyed"})
      expect(cert).not_to exist
    end

    it "fires an exception if the cert is not authorized and the message is not about the certificate being expired" do
      setup_order(with_order: false)
      cert.update(cert: "test-cert")
      expect(client).to receive(:revoke).and_raise(Acme::Client::Error::Unauthorized.new("The certificate is not authorized"))

      expect { nx.destroy }.to raise_error(Acme::Client::Error::Unauthorized)
      expect(cert).to exist
    end
  end

  describe "#acme_client" do
    it "returns a new acme client" do
      key = Clec::Cert.ec_key
      cert.update(account_key: key.to_der, kid: "test-kid")
      expect(Acme::Client).to receive(:new).with(private_key: instance_of(OpenSSL::PKey::EC), directory: Config.acme_directory, kid: "test-kid").and_return("client")

      expect(nx.acme_client).to eq "client"
    end

    it "returns nil if account key is not set" do
      expect(nx.acme_client).to be_nil
    end
  end

  describe "#acme_order" do
    it "returns the acme order" do
      cert.update(order_url: "test-order-url")
      client = instance_double(Acme::Client)
      expect(nx).to receive(:acme_client).and_return(client)
      expect(client).to receive(:order).with(url: "test-order-url").and_return("order")

      expect(nx.acme_order).to eq "order"
    end

    it "returns nil if order_url is nil" do
      expect(nx.acme_order).to be_nil
    end
  end

  describe "#dns_zone" do
    it "returns the dns zone" do
      expect(nx.dns_zone).to eq dns_zone
    end

    it "returns nil if dns_zone_id is not set" do
      no_zone_cert = Cert.create(hostname: "no-zone-host", dns_zone_id: nil)
      no_zone_strand = Strand.create_with_id(no_zone_cert, prog: "Vnet::CertNexus", label: "start", stack: [{"restarted" => 0}])
      no_zone_nx = described_class.new(no_zone_strand)
      expect(no_zone_nx.dns_zone).to be_nil
    end
  end
end
