# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::DnsZone::DnsServerNexus do
  subject(:nx) { described_class.new(st) }

  let(:server) { DnsServer.create(name: "ns.example.com") }
  let(:st) { described_class.assemble(server) }
  let(:project) { Project.create(name: "dns-test") }
  let(:vm) {
    value = create_vm(project_id: project.id, name: "dns-vm")
    Sshable.create_with_id(value, unix_user: "ubi", host: "dns.test")
    server.add_vm(value)
    value
  }
  let(:zone) {
    value = DnsZone.create(project_id: project.id, name: "example.com")
    value.add_dns_server(server)
    Strand.create_with_id(value, prog: "DnsZone::DnsZoneNexus", label: "wait")
    value
  }

  it "creates one persistent strand without resetting existing progress" do
    refresh_frame(nx, new_values: {"saved_state" => true})
    expect(described_class.assemble(server).stack.first).to include("saved_state" => true)
    expect(server.strand.id).to eq st.id
  end

  it "waits when no configuration was requested" do
    expect(st.unsynchronized_run).to be_a(Prog::Base::Nap)
    expect(st.reload).to have_attributes(prog: "DnsZone::DnsServerNexus", label: "wait")
  end

  it "exits after the server is deleted" do
    st
    server.destroy
    expect { nx.before_run }.to exit("msg" => "dns server deleted")
  end

  describe "#wait" do
    it "accepts a manual rollout and keeps it waiting until configuration completes" do
      st
      rollout = Prog::RolloutSemaphore.new(Prog::RolloutSemaphore.assemble(semaphore: "configure", ids: [server.id]))
      expect { rollout.start }.to hop("wait_current")
      st.unsynchronized_run
      expect(st.reload.label).to eq "configure"
      expect { rollout.wait_current }.to nap(6)

      st.unsynchronized_run
      expect(st.reload.label).to eq "wait"
      expect { rollout.wait_current }.to hop("start")
    end

    it "pages when configuration has not completed by the deadline" do
      st
      server.incr_configure
      st.unsynchronized_run
      refresh_frame(nx, new_values: {"deadline_at" => st.time_string(Time.now - 1)})

      expect { st.unsynchronized_run }.to change { Page.active.count }.by(1)
      expect(st.reload.label).to eq "wait"
    end
  end

  describe "#configure" do
    before do
      vm
      st.update(label: "configure")
      server.incr_configure
    end

    it "configures each VM once in sequence even when several zones share the server" do
      other = create_vm(project_id: project.id, name: "dns-vm-2")
      Sshable.create_with_id(other, unix_user: "ubi", host: "dns-2.test")
      server.add_vm(other)
      zone
      DnsZone.create(project_id: project.id, name: "example.net").add_dns_server(server)

      nx.dns_server.vms.each do |target|
        expect(target.sshable).to receive(:_cmd).with("true").ordered.and_return("")
        expect(target.sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: nx.dns_server.knot_config).ordered
        expect(target.sshable).to receive(:_cmd).with("sudo -u knot knotc reload").ordered do
          expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq 1
        end
      end

      expect { nx.configure }.to hop("wait")
      expect(Semaphore.where(strand_id: server.id, name: "configure")).to be_empty
      expect(st.stack.length).to eq 1
      expect(st.children_dataset).to be_empty
    end

    it "preserves a request arriving during configuration" do
      old_ids = Semaphore.where(strand_id: server.id, name: "configure").select_map(:id)
      sshable = nx.dns_server.vms.first.sshable
      expect(sshable).to receive(:_cmd).with("true").and_return("")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: nx.dns_server.knot_config) do
        server.incr_configure
      end
      expect(sshable).to receive(:_cmd).with("sudo -u knot knotc reload")

      expect { nx.configure }.to hop("wait")
      remaining = Semaphore.where(strand_id: server.id, name: "configure")
      expect(remaining.count).to eq 1
      expect(remaining.where(id: old_ids)).to be_empty
      expect { described_class.new(st).wait }.to hop("configure")
    end

    it "skips a VM retired after the server's VM list was read" do
      target = nx.dns_server.vms.first
      server.retire_vm(target.id, force: true)
      expect(target.sshable).not_to receive(:_cmd)

      expect { nx.configure }.to hop("wait")
      expect(Semaphore.where(strand_id: server.id, name: "configure")).to be_empty
    end

    it "pages for an unreachable VM and continues configuring the remaining VMs" do
      other = create_vm(project_id: project.id, name: "dns-vm-2")
      Sshable.create_with_id(other, unix_user: "ubi", host: "dns-2.test")
      server.add_vm(other)
      missing, reachable = nx.dns_server.vms
      expect(missing.sshable).to receive(:_cmd).with("true").and_raise(IOError)
      expect(Clog).to receive(:emit).with("dns server vm unreachable, skipping configure", {vm_ubid: missing.ubid}).and_call_original
      expect(reachable.sshable).to receive(:_cmd).with("true").and_return("")
      expect(reachable.sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: nx.dns_server.knot_config)
      expect(reachable.sshable).to receive(:_cmd).with("sudo -u knot knotc reload")

      expect { nx.configure }.to hop("wait")
      page = Page.from_tag_parts("DnsServerVmConfigure", missing.id)
      expect(page).to have_attributes(summary: "DNS VM #{missing.ubid} unreachable during configuration", resource_id: missing.id, severity: "error")
      expect(page.details.fetch("related_resources")).to eq [missing.ubid]
      expect(Strand[page.id]).to have_attributes(prog: "PageNexus", label: "start")
      expect(Semaphore.where(strand_id: server.id, name: "configure")).to be_empty
    end

    it "keeps the request and outage page pending until configuration succeeds" do
      page = Prog::PageNexus.assemble("DNS VM unreachable during configuration", ["DnsServerVmConfigure", vm.id], vm.ubid, resource_id: vm.id).subject
      sshable = nx.dns_server.vms.first.sshable
      expect(sshable).to receive(:_cmd).with("true").twice.and_return("")
      expect(sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: nx.dns_server.knot_config).twice
      expect(sshable).to receive(:_cmd).with("sudo -u knot knotc reload").ordered.and_raise(IOError)
      expect(sshable).to receive(:_cmd).with("sudo -u knot knotc reload").ordered.and_return("")
      expect(Clog).to receive(:emit).with("dns server vm configuration failed, retrying", hash_including(vm_ubid: vm.ubid)).and_call_original

      expect { nx.configure }.to nap(5)
      expect(Semaphore.where(strand_id: page.id, name: "resolve")).to be_empty
      expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq 1

      expect { nx.configure }.to hop("wait")
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq 1
      expect(Semaphore.where(strand_id: server.id, name: "configure")).to be_empty
    end

    [IOError.new("disconnected"), Sshable::SshError.new("write", "", "failed", 1, nil), Net::SSH::AuthenticationFailed.new("authentication failed")].each do |error|
      it "commits an earlier outage page when a later VM raises #{error.class}" do
        other = create_vm(project_id: project.id, name: "dns-vm-2")
        Sshable.create_with_id(other, unix_user: "ubi", host: "dns-2.test")
        server.add_vm(other)
        missing, failing = nx.dns_server.vms
        expect(missing.sshable).to receive(:_cmd).with("true").and_raise(IOError)
        expect(failing.sshable).to receive(:_cmd).with("true").and_return("")
        expect(failing.sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: nx.dns_server.knot_config).and_raise(error)
        expect(Clog).to receive(:emit).with("dns server vm unreachable, skipping configure", {vm_ubid: missing.ubid}).and_call_original
        expect(Clog).to receive(:emit).with(
          "dns server vm configuration failed, retrying",
          hash_including(vm_ubid: failing.ubid, exception: hash_including(class: error.class.to_s, message: error.message, backtrace: kind_of(Array))),
        ).and_call_original

        result = DB.transaction(savepoint: true) { catch(:prog_return) { nx.configure } }

        expect(result).to be_a(Prog::Base::Nap).and have_attributes(seconds: 5)
        page = Page.from_tag_parts("DnsServerVmConfigure", missing.id)
        expect(page).to have_attributes(resource_id: missing.id)
        expect(Strand[page.id]).to have_attributes(prog: "PageNexus", label: "start")
        expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq 1
      end
    end

    it "allows zone record updates while server configuration is pending" do
      zone.insert_record(record_name: "new.example.com", type: "A", ttl: 10, data: "192.0.2.1")
      updater = Prog::DnsZone::DnsZoneNexus.new(zone.strand)
      expect(updater.dns_zone.dns_servers.first.vms.first.sshable).to receive(:_cmd)
        .with("sudo -u knot knotc", stdin: "zone-abort example.com\nzone-begin example.com\nzone-set example.com new.example.com. 10 A 192.0.2.1\nzone-commit example.com")
        .and_return("OK\n" * 4)

      expect { updater.refresh_dns_servers }.to hop("purge_obsolete_records")
      expect(Semaphore.where(strand_id: zone.id, name: "refresh_dns_servers")).to be_empty
      expect(DB[:seen_dns_records_by_dns_servers].where(dns_server_id: server.id).count).to eq 1
      expect(st.reload).to have_attributes(prog: "DnsZone::DnsServerNexus", label: "configure")
      expect(Semaphore.where(strand_id: server.id, name: "configure").count).to eq 1
    end
  end
end
