# frozen_string_literal: true

RSpec.describe Prog::Vnet::LoadBalancerNexus do
  subject(:nx) {
    described_class.new(st)
  }

  let(:st) {
    cert = Prog::Vnet::CertNexus.assemble("test-host-name", dns_zone.id).subject
    lb = described_class.assemble(ps.id, name: "test-lb", src_port: 80, dst_port: 8080, health_check_protocol: "https", cert_enabled: true).subject
    lb.add_cert(cert)
    lb.strand
  }
  let(:ps) {
    prj = Project.create(name: "test-prj")
    Prog::Vnet::SubnetNexus.assemble(prj.id, name: "test-ps").subject
  }
  let(:dns_zone) {
    dz = DnsZone.create(project_id: ps.project_id, name: "lb.ubicloud.com")
    Strand.create_with_id(dz, prog: "DnsZone::DnsZoneNexus", label: "wait")
    dz
  }

  before do
    allow(Config).to receive_messages(load_balancer_service_hostname: "lb.ubicloud.com", load_balancer_service_project_id: ps.project_id)
  end

  def create_vm_with_ips(name:, private_ipv4:, private_ipv6:, public_ipv4: nil, public_ipv6: nil)
    nic = Prog::Vnet::NicNexus.assemble(ps.id, name: "#{name}-nic", ipv4_addr: private_ipv4, ipv6_addr: private_ipv6).subject
    vm = Prog::Vm::Nexus.assemble("pub key", ps.project_id, name:, private_subnet_id: ps.id, nic_id: nic.id).subject
    vm.update(ephemeral_net6: public_ipv6) if public_ipv6
    add_ipv4_to_vm(vm, public_ipv4) if public_ipv4
    vm
  end

  def add_lb_vm(stack: nil, **vm_args)
    nx.load_balancer.update(stack:) if stack
    vm = create_vm_with_ips(**vm_args)
    nx.load_balancer.add_vm(vm)
    vm
  end

  describe ".assemble" do
    it "fails if private subnet does not exist" do
      expect {
        described_class.assemble("0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "Given subnet doesn't exist with the id 0a9a166c-e7e7-4447-ab29-7ea442b5bb0e"
    end

    it "creates a new load balancer" do
      lb = described_class.assemble(ps.id, name: "test-lb2", src_port: 80, dst_port: 8080).subject
      expect(LoadBalancer.count).to eq 1
      expect(lb.project).to eq ps.project
      expect(lb.hostname).to eq "test-lb2.#{ps.ubid[-5...]}.lb.ubicloud.com"
    end

    it "creates a new load balancer with custom hostname" do
      dz = DnsZone.create(project_id: ps.project_id, name: "custom.ubicloud.com")
      lb = described_class.assemble(ps.id, name: "test-lb2", src_port: 80, dst_port: 8080, custom_hostname_prefix: "test-custom-hostname", custom_hostname_dns_zone_id: dz.id).subject
      expect(LoadBalancer.count).to eq 1
      expect(lb.project).to eq ps.project
      expect(lb.hostname).to eq "test-custom-hostname.custom.ubicloud.com"
    end
  end

  describe "#wait" do
    it "naps for 1 day if nothing to do" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect { nx.wait }.to nap(86400)
    end

    it "hops to update vm load balancers" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect(nx).to receive(:when_update_load_balancer_set?).and_yield
      expect { nx.wait }.to hop("update_vm_load_balancers")
    end

    it "rewrites dns records" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect(nx).to receive(:when_rewrite_dns_records_set?).and_yield
      expect { nx.wait }.to hop("rewrite_dns_records")
    end

    it "creates new cert if refresh_cert semaphore is set" do
      st.subject.incr_refresh_cert
      fresh_nx = described_class.new(st)
      expect { fresh_nx.wait }.to hop("create_new_cert")
    end

    it "creates new cert if needed" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(true)
      expect(nx.load_balancer).to receive(:incr_refresh_cert)
      expect { nx.wait }.to hop("create_new_cert")
    end
  end

  describe "#create_new_cert" do
    it "creates a new cert" do
      expect { nx.create_new_cert }.to hop("wait_cert_provisioning")
        .and change { Strand.where(prog: "Vnet::CertNexus").count }.from(1).to(2)
        .and change { Strand.where(prog: "Vnet::CertNexus").all.select { it.stack[0]["add_private"] }.count }.from(0).to(1)
        .and change { nx.load_balancer.certs.count }.from(1).to(2)
      expect(st.reload.stack[0]["cert"]).to be_a String
    end

    it "creates a cert without dns zone in development" do
      expect(Config).to receive(:development?).at_least(:once).and_return(true)
      expect(Config).to receive(:load_balancer_service_project_id).and_return("00000000-0000-0000-0000-000000000000")
      expect { nx.create_new_cert }.to hop("wait_cert_provisioning")
      expect(Strand.where(prog: "Vnet::CertNexus").count).to eq 2
      expect(nx.load_balancer.certs.count).to eq 2
    end
  end

  describe "#wait_cert_provisioning" do
    it "naps for 60 seconds if need_certificates? is true" do
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(true)
      expect { nx.wait_cert_provisioning }.to nap(60)
    end

    it "naps for 60 seconds if cert is set in frame but does not have valid cert entry" do
      cert = Cert.create(hostname: nx.load_balancer.hostname)
      refresh_frame(nx, new_values: {"cert" => cert.id})
      expect { nx.wait_cert_provisioning }.to nap(60)
    end

    it "hops to wait_cert_broadcast if certificate is ready and refresh_cert is set" do
      vm = Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "testvm", private_subnet_id: ps.id).subject
      nx.load_balancer.add_vm(vm)
      nx.load_balancer.incr_refresh_cert
      expect(Strand.where(prog: "Vnet::CertServer", label: "setup_cert_server").count).to eq 1
      cert = Cert.create(hostname: nx.load_balancer.hostname, cert: "a")
      refresh_frame(nx, new_values: {"cert" => cert.id})
      expect { nx.wait_cert_provisioning }.to hop("wait_cert_broadcast")
      expect(Strand.where(prog: "Vnet::CertServer", label: "reshare_certificate").count).to eq 1
    end

    it "hops to wait need_certificates? and refresh_cert are false" do
      vm = Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "testvm", private_subnet_id: ps.id).subject
      nx.load_balancer.add_vm(vm)
      expect(Strand.where(prog: "Vnet::CertServer", label: "setup_cert_server").count).to eq 1
      expect(nx.load_balancer).to receive(:need_certificates?).and_return(false)
      expect { nx.wait_cert_provisioning }.to hop("wait")
      expect(st.reload.stack[0].fetch("cert")).to be_nil
      expect(Strand.where(prog: "Vnet::CertServer", label: "reshare_certificate").all).to be_empty
    end
  end

  describe "#wait_cert_broadcast" do
    it "naps for 1 second if not all children are done" do
      vm = Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "testvm", private_subnet_id: ps.id).subject
      nx.load_balancer.add_vm(vm)
      expect { nx.wait_cert_broadcast }.to nap(1)
    end

    it "hops to wait if all children are done and no certs to remove" do
      expect(nx).to receive(:reap).and_yield
      active_cert = Prog::Vnet::CertNexus.assemble("active-cert", dns_zone.id).subject
      expect(nx.load_balancer).to receive(:active_cert).and_return(active_cert)
      expect { nx.wait_cert_broadcast }.to hop("wait")
    end

    it "removes certs if all children are done and there are certs to remove" do
      cert_to_remove = Prog::Vnet::CertNexus.assemble("cert-to-remove", dns_zone.id).subject
      cert_to_remove.update(created_at: Time.now - 60 * 60 * 24 * 30 * 4)
      active_cert = Prog::Vnet::CertNexus.assemble("active-cert", dns_zone.id).subject
      expect(nx.load_balancer).to receive(:active_cert).and_return(active_cert)
      nx.load_balancer.add_cert(cert_to_remove)
      nx.load_balancer.add_cert(active_cert)

      expect(nx).to receive(:reap).and_yield

      expect { nx.wait_cert_broadcast }.to hop("wait")
        .and change { cert_to_remove.strand.semaphores_dataset.where(name: "destroy").count }.from(0).to(1)
      expect(nx.load_balancer.reload.certs.count).to eq 1
      expect(st.reload.stack[0].fetch("cert")).to be_nil
    end
  end

  describe "#update_vm_load_balancers" do
    it "updates load balancers for all vms" do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "test-vm#{it}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(it) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
      expect(st.children_dataset.where(prog: "Vnet::UpdateLoadBalancerNode", label: "update_load_balancer").count).to eq 3
    end
  end

  context "with vms and update_load_balancer children" do
    before do
      vms = Array.new(3) { Prog::Vm::Nexus.assemble("pub key", ps.project_id, name: "test-vm#{it}", private_subnet_id: ps.id).subject }
      vms.each { st.subject.add_vm(it) }
      expect { nx.update_vm_load_balancers }.to hop("wait_update_vm_load_balancers")
    end

    describe "#wait_update_vm_load_balancers" do
      it "naps for 1 second if not all children are done" do
        Strand.create(parent_id: st.id, prog: "UpdateLoadBalancerNode", label: "start", lease: Time.now + 10)
        expect { nx.wait_update_vm_load_balancers }.to nap(1)
      end

      it "decrements update_load_balancer and hops to wait if all children are done" do
        st.children.map(&:destroy)
        expect(nx).to receive(:decr_update_load_balancer)
        expect { nx.wait_update_vm_load_balancers }.to hop("wait")
      end
    end

    describe "#destroy" do
      it "adds destroy semaphore to all children and hops to wait_destroy children" do
        expect(nx).to receive(:decr_destroy)
        expect { nx.destroy }.to hop("wait_destroy_children")

        expect(Semaphore.where(name: "destroy").select_order_map(:strand_id)).to eq st.children.map(&:id).sort
      end
    end

    describe "#wait_destroy_children" do
      it "naps 5 if reap is not a success" do
        expect { nx.wait_destroy_children }.to nap(5)
      end

      it "creates LoadBalancerRemoveVm children and hops wait_all_vms_removed" do
        st.children_dataset.destroy
        expect { nx.wait_destroy_children }.to hop("wait_all_vms_removed")
        expect(Strand.where(prog: "Vnet::LoadBalancerRemoveVm", parent_id: nx.strand.id).count).to eq 3
      end
    end
  end

  describe "#wait_all_vms_removed" do
    it "naps 5 if reap is not a success" do
      Strand.create(parent_id: st.id, prog: "Vnet::LoadBalancerRemoveVm", label: "mark_vm_ports_as_evacuating", stack: [{}], lease: Time.now + 10)
      expect { nx.wait_all_vms_removed }.to nap(5)
    end

    it "exits and cleans up if reap is a success" do
      lb = nx.load_balancer
      expect { nx.wait_all_vms_removed }.to exit({"msg" => "load balancer deleted"})
        .and change { ps.strand.semaphores_dataset.where(name: "update_firewall_rules").count }.from(0).to(1)
      expect(lb).not_to exist
    end

    it "exits without deleting dns record if no dns zone" do
      expect(Config).to receive(:load_balancer_service_project_id).and_return("00000000-0000-0000-0000-000000000000")
      lb_id = nx.load_balancer.id
      expect { nx.wait_all_vms_removed }.to exit({"msg" => "load balancer deleted"})
      expect(LoadBalancer[lb_id]).to be_nil
    end
  end

  describe "#rewrite_dns_records" do
    def dns_records_for(hostname)
      DnsRecord.where(dns_zone_id: dns_zone.id, tombstoned: false)
        .where(Sequel.like(:name, "%#{DB.dataset.escape_like(hostname)}.%")).all
    end

    ipv4_on = {"ipv4" => true, "ipv6" => false, "dual" => true}
    ipv6_on = {"ipv4" => false, "ipv6" => true, "dual" => true}
    bools = [true, false].freeze

    # With the current production code, rewrite_dns_records naps 5 when a
    # VM's public IP is expected but not yet assigned:
    # - ipv6_enabled && !ip6_string => nap 5
    # - ipv4_enabled && !ip4_string && ip4_enabled (on VM) => nap 5
    # Test VMs default to ip4_enabled=false, so only the ipv6 case triggers.
    ["ipv4", "ipv6", "dual"].each do |stack|
      bools.each do |has_pub4|
        bools.each do |has_pub6|
          # If ipv6 is enabled for this stack but no public ipv6 assigned, code naps
          expects_nap = ipv6_on[stack] && !has_pub6

          it "#{stack} stack, pub4=#{has_pub4}, pub6=#{has_pub6}" do
            vm_args = {name: "vm", private_ipv4: "10.0.0.1/32", private_ipv6: "fd10:9b0b:6b4b:8fb2::/64"}
            vm_args[:public_ipv4] = "203.0.113.1/32" if has_pub4
            vm_args[:public_ipv6] = "2001:db8:1::/64" if has_pub6
            add_lb_vm(stack:, **vm_args)

            if expects_nap
              expect { nx.rewrite_dns_records }.to nap(5)
              expect(DnsRecord.where(dns_zone_id: dns_zone.id, tombstoned: false).all).to be_empty
            else
              expect { nx.rewrite_dns_records }.to hop("wait")

              expected = []
              if ipv4_on[stack]
                expected << [:pub, "A", "203.0.113.1"] if has_pub4
                expected << [:priv, "A", "10.0.0.1"]
              end
              if ipv6_on[stack]
                expected << [:pub, "AAAA", "2001:db8:1::2"] if has_pub6
                expected << [:priv, "AAAA", "fd10:9b0b:6b4b:8fb2::2"]
              end

              hostname = nx.load_balancer.hostname
              expected_records = expected.map { |prefix, type, data|
                name = (prefix == :pub) ? hostname : "private.#{hostname}"
                [name, type, data]
              }
              records = dns_records_for(hostname).map { [it.name.chomp("."), it.type, it.data] }.uniq
              expect(records).to match_array(expected_records)
            end
          end
        end
      end
    end

    it "does not rewrite dns records if no vms" do
      expect { nx.rewrite_dns_records }.to hop("wait")
      expect(DnsRecord.all).to be_empty
    end

    it "does not check vms to dns if no dns zone" do
      nx
      expect(Config).to receive(:load_balancer_service_project_id).and_return("00000000-0000-0000-0000-000000000000")
      expect { nx.rewrite_dns_records }.to hop("wait")
      expect(DnsRecord.all).to be_empty
    end

    it "naps 5 if VM public IPv4 address is not yet assigned but ip4_enabled" do
      vm = add_lb_vm(
        stack: "dual",
        name: "ipv4-pending-vm",
        private_ipv4: "10.0.0.7/32",
        private_ipv6: "fd10:9b0b:6b4b:8fb2::/64",
        public_ipv6: "2001:db8:2::/64"
      )
      vm.update(ip4_enabled: true)
      expect { nx.rewrite_dns_records }.to nap(5)
      expect(DnsRecord.where(dns_zone_id: dns_zone.id, tombstoned: false).all).to be_empty
    end
  end
end
