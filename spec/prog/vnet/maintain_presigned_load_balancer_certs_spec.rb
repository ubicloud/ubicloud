# frozen_string_literal: true

RSpec.describe Prog::Vnet::MaintainPresignedLoadBalancerCerts do
  subject(:prog) { described_class.new(st) }

  let(:st) {
    Strand.create(
      prog: "Vnet::MaintainPresignedLoadBalancerCerts",
      label: "wait",
      stack: [{"last_cert_created" => Time.now.to_i - 70}],
    )
  }

  let(:project_id) { Project.create(name: "Test-MaintainPresignedLoadBalancerCerts").id }
  let(:dns_zone) { DnsZone.create(project_id:, name: "lb2.ubicloud.com") }

  before do
    allow(Config).to receive_messages(
      load_balancer_service_hostname_v2: "lb2.ubicloud.com",
      load_balancer_service_project_id: project_id,
    )
  end

  describe "#wait" do
    let(:min_certs) { described_class::MIN_CERTS }

    it "naps if last cert was created too recently" do
      refresh_frame(prog, new_values: {"last_cert_created" => Time.now.to_i - 50})
      expect { prog.wait }.to nap(5..15)
    end

    it "naps if sufficient certs have been created" do
      Cert.dataset.import([:id, :hostname], Array.new(min_certs) { [Cert.generate_uuid, "test-#{it}.lb2.ubicloud.com"] })
      DB[:presigned_load_balancer_cert].import([:load_balancer_id, :cert_id], Cert.select_map(:id).map { [LoadBalancer.generate_uuid, it] })
      expect { prog.wait }.to nap(60 * 60)
    end

    it "hops if sufficient certs have not been created" do
      expect { prog.wait }.to hop("request_cert")
    end

    it "adds destroy semaphore to old presigned certs before checking for sufficient certs" do
      Cert.dataset.import([:id, :hostname], Array.new(min_certs) { [Cert.generate_uuid, "test-#{it}.lb2.ubicloud.com"] })
      Strand.dataset.insert([:id, :prog, :label], Cert.select(:id, "Vnet::CertNexus", "wait"))
      DB[:presigned_load_balancer_cert].import(
        [:load_balancer_id, :cert_id, :created_at],
        Cert.select_map(:id).map { [LoadBalancer.generate_uuid, it, Time.utc(2026)] },
      )
      expect { prog.wait }.to hop("request_cert")
        .and change { DB[:presigned_load_balancer_cert].count }.from(min_certs).to(0)
        .and change { Semaphore.where(name: "destroy", strand_id: Cert.select(:id)).count }.from(0).to(min_certs)
    end
  end

  describe "#request_cert" do
    it "creates a cert, sets deadline and hops" do
      dns_zone
      expect { prog.request_cert }.to hop("wait_for_signed_cert")
      frame = prog.strand.stack[0]
      load_balancer_id, cert_id = frame.values_at("load_balancer_id", "cert_id")
      expect(Cert.count).to eq 1
      cert = Cert.first
      lb_ubid = UBID.to_ubid(load_balancer_id)
      expect(lb_ubid).to start_with("1b")
      expect(cert_id).to eq cert.id
      expect(cert.strand.label).to eq "start"
      expect(cert.hostname).to eq "*.#{lb_ubid}.lb2.ubicloud.com"
      expect(cert.private_hostname).to eq "*.#{lb_ubid}.private.lb2.ubicloud.com"
      expect(cert.dns_zone_id).to eq dns_zone.id
      expect(frame["deadline_target"]).to eq "wait"
      expect(Time.parse(frame["deadline_at"])).to be_within(5).of(Time.now + 60 * 30)
    end
  end

  describe "#wait_for_signed_cert" do
    before do
      refresh_frame(prog, new_values: {
        "cert_id" => Cert.generate_uuid,
        "load_balancer_id" => LoadBalancer.generate_uuid,
      })
    end

    it "info pages and hops if cert strand does not exist" do
      expect { prog.wait_for_signed_cert }.to hop("wait")
        .and change { Page.where(severity: "info").count }.from(0).to(1)
        .and not_change { DB[:presigned_load_balancer_cert].count }
      frame = prog.strand.stack[0]
      expect(frame.fetch("load_balancer_id")).to be_nil
      expect(frame.fetch("cert_id")).to be_nil
      expect(frame.fetch("last_cert_created")).to be_within(5).of(Time.now.to_i)
    end

    it "naps if cert strand is not in wait" do
      frame = prog.strand.stack[0]
      Strand.create_with_id(frame.fetch("cert_id"), prog: "Vnet::CertNexus", label: "start")
      refresh_frame(prog, new_values: {"last_cert_created" => Time.now.to_i - 50})
      expect { prog.wait_for_signed_cert }.to nap(10)
    end

    it "hops if cert strand is in wait" do
      frame = prog.strand.stack[0]
      expect_load_balancer_id = frame.fetch("load_balancer_id")
      expect_cert_id = frame.fetch("cert_id")
      Strand.create_with_id(expect_cert_id, prog: "Vnet::CertNexus", label: "wait")
      Cert.create_with_id(expect_cert_id, hostname: "*.#{UBID.to_ubid(expect_load_balancer_id)}.lb2.ubicloud.com")

      expect { prog.wait_for_signed_cert }.to hop("wait")
        .and not_change { Page.where(severity: "info").count }
        .and change { DB[:presigned_load_balancer_cert].count }.from(0).to(1)
      load_balancer_id, cert_id, created_at = DB[:presigned_load_balancer_cert].get([:load_balancer_id, :cert_id, :created_at])
      expect(load_balancer_id).to eq expect_load_balancer_id
      expect(cert_id).to eq expect_cert_id
      expect(created_at).to be_within(5).of(Time.now)
      frame = prog.strand.stack[0]
      expect(frame.fetch("load_balancer_id")).to be_nil
      expect(frame.fetch("cert_id")).to be_nil
      expect(frame.fetch("last_cert_created")).to be_within(5).of(Time.now.to_i)
    end
  end
end
