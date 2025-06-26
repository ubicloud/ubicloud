# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupGrafana do
  subject(:sn) { described_class.new(st) }

  let(:st) { Strand.create(prog: "SetupGrafana", label: "start", stack: [{"subject_id" => sshable.id, "cert_email" => "email@gmail.com", "domain" => "grafana.domain.com"}]) }

  let(:sshable) { Sshable.create(host: "test.localhost", raw_private_key_1: SshKey.generate.keypair) }

  before do
    allow(sn).to receive(:sshable).and_return(sshable)
  end

  describe "#domain" do
    it "returns the domain based on the stack" do
      expect(sn.domain).to eq("grafana.domain.com")
    end
  end

  describe "#cert_email" do
    it "returns the cert email based on the stack" do
      expect(sn.cert_email).to eq("email@gmail.com")
    end
  end

  describe "#assemble" do
    it "fails if domain is not provided" do
      expect { described_class.assemble(sshable.id, grafana_domain: "", certificate_owner_email: "cert@gmail.com") }.to raise_error(RuntimeError)
    end

    it "fails if cert_email is not provided" do
      expect { described_class.assemble(sshable.id, grafana_domain: "domain.com", certificate_owner_email: "") }.to raise_error(RuntimeError)
    end

    it "fails if sshable is not provided or does not exist" do
      expect { described_class.assemble("vm6htsmcfx5t1p60s609v49fbf", grafana_domain: "domain.com", certificate_owner_email: "cert@gmail.com") }.to raise_error(RuntimeError)
    end

    it "creates an strand with the right input" do
      st = described_class.assemble(sshable.id, grafana_domain: "domain.com", certificate_owner_email: "cert@gmail.com")
      st.reload
      expect(st.label).to eq("start")
    end
  end

  describe "#install_rhizome" do
    it "buds a bootstrap rhizome prog and hops to wait_for_rhizome" do
      expect(sn).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "host", "subject_id" => sshable.id, "user" => sshable.unix_user})
      expect { sn.start }.to hop("wait_for_rhizome")
    end
  end

  describe "#wait_for_rhizome" do
    it "donates if install_rhizome is not done" do
      Strand.create(parent_id: st.id, prog: "BootstrapRhizome", label: "start", stack: [{}], lease: Time.now + 10)
      expect { sn.wait_for_rhizome }.to nap(120)
    end

    it "hops to install_grafana when rhizome is done" do
      expect { sn.wait_for_rhizome }.to hop("install_grafana")
    end
  end

  describe "#install_grafana" do
    it "starts to install the grafana if its the first time" do
      expect(sn).to receive(:domain).and_return("grafana.domain.com")
      expect(sn).to receive(:cert_email).and_return("email@gmail.com")
      expect(sshable).to receive(:d_check).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with("install_grafana", "sudo", "host/bin/setup-grafana", "grafana.domain.com", "email@gmail.com")
      expect { sn.install_grafana }.to nap(10)
    end

    it "cleans up and pops when the installation is done" do
      expect(sshable).to receive(:d_check).and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("install_grafana")
      expect { sn.install_grafana }.to exit({"msg" => "grafana was setup"})
    end

    it "naps when strand is in the middle of execution" do
      expect(sshable).to receive(:d_check).and_return("InProgress")
      expect { sn.install_grafana }.to nap(10)
    end

    it "naps for a long time when the installation fails" do
      expect(sshable).to receive(:d_check).and_return("Failed")
      expect { sn.install_grafana }.to nap(65536)
    end

    it "naps forever if the daemonizer check returns something unknown" do
      expect(sshable).to receive(:d_check).and_return("Unknown")
      expect { sn.install_grafana }.to nap(65536)
    end
  end
end
