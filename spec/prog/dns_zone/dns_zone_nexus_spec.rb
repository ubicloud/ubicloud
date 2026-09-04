# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::DnsZone::DnsZoneNexus do
  subject(:nx) { described_class.new(dns_zone.strand) }

  let(:prj) { Project.create(name: "test-prj") }
  let(:dns_zone) {
    dz = DnsZone.create(project_id: prj.id, name: "postgres.ubicloud.com")
    Strand.create_with_id(dz, prog: "DnsZone::DnsZoneNexus", label: "wait")
    dz.add_dns_server(dns_server)
    dz
  }
  let(:dns_server) { DnsServer.create(name: "ns.ubicloud.com") }
  let(:vm) {
    v = create_vm(project_id: prj.id, name: "dns-vm")
    Sshable.create_with_id(v, unix_user: "root", host: "test-host")
    dns_server.add_vm(v)
    v
  }

  describe "#wait" do
    it "hops to refresh_dns_servers if refresh_dns_servers semaphore is set" do
      nx.incr_refresh_dns_servers
      expect { nx.wait }.to hop("refresh_dns_servers")
    end

    it "hops to purge_obsolete_records if last purge happened more than 1 hour ago" do
      dns_zone.update(last_purged_at: Time.now - 60 * 60 * 2)
      expect { nx.wait }.to hop("purge_obsolete_records")
    end

    it "naps if there is nothing to do" do
      expect { nx.wait }.to nap(10)
    end

    it "hops to configure when the configure semaphore is set" do
      nx.incr_configure
      expect { nx.wait }.to hop("configure")
      expect(Semaphore.where(strand_id: dns_zone.id, name: "configure")).to be_empty
    end

    it "starts requested configuration before pending record updates" do
      nx.incr_configure
      nx.incr_refresh_dns_servers

      expect { nx.wait }.to hop("configure")

      expect(Semaphore.where(strand_id: dns_zone.id, name: "configure")).to be_empty
      expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).not_to be_empty
    end
  end

  describe "#configure" do
    it "queues each dns server vm and hops to wait_configure" do
      vm
      expect { nx.configure }.to hop("wait_configure")
      expect(nx.configure_queue).to eq [{"subject_id" => vm.id, "dns_server_id" => dns_server.id}]
    end
  end

  describe "#wait_configure" do
    it "returns to wait when no DNS VMs are queued" do
      st = dns_zone.strand.update(label: "configure")
      st.unsynchronized_run
      st.unsynchronized_run

      expect(st.reload.label).to eq "wait"
      expect(st.stack.first.fetch("configure_queue")).to be_empty
      expect(st.children_dataset).to be_empty
    end

    context "when configuration progress must precede record refresh" do
      let(:st) { dns_zone.strand }

      before do
        vm
        other_vm = create_vm(project_id: prj.id, name: "dns-vm-2")
        Sshable.create_with_id(other_vm, unix_user: "root", host: "test-host-2")
        dns_server.add_vm(other_vm)
        st.update(label: "configure")
        st.unsynchronized_run
      end

      it "commits the first child before attempting pending record updates" do
        dns_zone.insert_record(record_name: "new.postgres.ubicloud.com", type: "A", ttl: 10, data: "5.6.7.8")

        expect(st.unsynchronized_run).to have_attributes(seconds: 5)

        expect(st.reload.children_dataset.count).to eq 1
        expect(st.stack.first.fetch("configure_queue").length).to eq 1
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).not_to be_empty
        expect(DB[:seen_dns_records_by_dns_servers].where(dns_server_id: dns_server.id)).to be_empty
      end

      it "commits reaping and the next child before attempting pending record updates" do
        st.unsynchronized_run
        child = st.children_dataset.first
        child.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}))
        dns_zone.insert_record(record_name: "new.postgres.ubicloud.com", type: "A", ttl: 10, data: "5.6.7.8")
        next_vm_id = st.reload.stack.first.fetch("configure_queue").first.fetch("subject_id")

        expect(st.unsynchronized_run).to have_attributes(seconds: 5)

        expect(Strand[child.id]).to be_nil
        expect(st.children_dataset.count).to eq 1
        expect(st.children_dataset.first.stack.first.fetch("subject_id")).to eq next_vm_id
        expect(st.reload.stack.first.fetch("configure_queue")).to be_empty
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).not_to be_empty
      end

      it "returns to record updates after a finite queue of fast children" do
        dns_zone.insert_record(record_name: "new.postgres.ubicloud.com", type: "A", ttl: 10, data: "5.6.7.8")
        scheduled_vms = []
        2.times do
          expect(st.unsynchronized_run).to have_attributes(seconds: 5)
          expect(st.children_dataset.count).to eq 1
          child = st.children_dataset.first
          scheduled_vms << child.stack.first.fetch("subject_id")
          child.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}))
        end
        st.unsynchronized_run

        expect(scheduled_vms).to match_array dns_server.vms_dataset.select_map(:id)
        expect(st.reload.label).to eq "wait"
        expect(st.children_dataset).to be_empty
        runner = described_class.new(st)
        expect { runner.wait }.to hop("refresh_dns_servers")
        runner.dns_zone.dns_servers.first.vms.each do |vm|
          expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: "zone-abort postgres.ubicloud.com\nzone-begin postgres.ubicloud.com\nzone-set postgres.ubicloud.com new.postgres.ubicloud.com. 10 A 5.6.7.8\nzone-commit postgres.ubicloud.com").and_return("OK\n" * 4)
        end
        expect { runner.refresh_dns_servers }.to hop("purge_obsolete_records")
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).to be_empty
      end

      it "preserves an additional rollout request and eventually returns to pending records" do
        dns_zone.insert_record(record_name: "new.postgres.ubicloud.com", type: "A", ttl: 10, data: "5.6.7.8")
        scheduled_vms = []
        2.times do |rollout|
          2.times do |index|
            expect(st.unsynchronized_run).to have_attributes(seconds: 5)
            expect(st.children_dataset.count).to eq 1
            child = st.children_dataset.first
            scheduled_vms << child.stack.first.fetch("subject_id")
            dns_zone.incr_configure if rollout.zero? && index.zero?
            child.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}))
          end
          st.unsynchronized_run
          expect(st.reload.label).to eq "wait"
          st.unsynchronized_run
          if rollout.zero?
            expect(st.reload.label).to eq "configure"
            st.unsynchronized_run
          end
        end

        expect(scheduled_vms.tally.values).to eq [2, 2]
        expect(st.reload.label).to eq "refresh_dns_servers"
        expect(st.children_dataset).to be_empty
        expect(Semaphore.where(strand_id: dns_zone.id, name: "configure")).to be_empty
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).not_to be_empty
      end

      it "pages once for an expired rollout deadline without cancelling the active child" do
        st.unsynchronized_run
        child = st.children_dataset.first
        runner = described_class.new(st)
        refresh_frame(runner, new_values: {"deadline_at" => st.time_string(Time.now - 1), "deadline_target" => "wait", "deadline_page" => true})

        expect { st.unsynchronized_run }.to change { Page.active.count }.by(1)
        expect(st.reload.stack.first["deadline_notified"]).to be true
        expect { st.unsynchronized_run }.not_to change { Page.active.count }
        expect(st.children_dataset.select_map(:id)).to eq [child.id]
        expect(child.refresh.exitval).to be_nil
      end
    end

    context "with pending record changes and an active configuration child" do
      let(:old_record) { DnsRecord.create(dns_zone_id: dns_zone.id, name: "old.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", created_at: Time.now - 60) }
      let(:commands) {
        "zone-abort postgres.ubicloud.com\nzone-begin postgres.ubicloud.com\nzone-set postgres.ubicloud.com new.postgres.ubicloud.com. 10 A 5.6.7.8\nzone-unset postgres.ubicloud.com old.postgres.ubicloud.com. 10 A 1.2.3.4\nzone-commit postgres.ubicloud.com"
      }
      let(:runner) { described_class.new(dns_zone.strand.reload) }
      let(:sshable) { runner.dns_zone.dns_servers.first.vms.first.sshable }
      let(:child) { dns_zone.strand.children_dataset.first }

      before do
        vm
        other_vm = create_vm(project_id: prj.id, name: "dns-vm-2")
        Sshable.create_with_id(other_vm, unix_user: "root", host: "test-host-2")
        dns_server.add_vm(other_vm)
        dns_zone.strand.update(label: "configure")
        dns_zone.strand.unsynchronized_run
        dns_zone.strand.unsynchronized_run
        DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: old_record.id, dns_server_id: dns_server.id)
        dns_zone.insert_record(record_name: "new.postgres.ubicloud.com", type: "A", ttl: 10, data: "5.6.7.8")
        dns_zone.records_dataset.where(name: "new.postgres.ubicloud.com.").update(created_at: Time.now - 30)
        dns_zone.delete_record(record_name: old_record.name)
      end

      it "propagates additions and tombstones without advancing the configuration queue" do
        queue = runner.configure_queue.dup
        runner.dns_zone.dns_servers.first.vms.each do |vm|
          expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands).and_return("OK\n" * 5)
        end

        expect { runner.wait_configure }.to nap(10)

        expect(runner.configure_queue).to eq queue
        expect(child.refresh.exitval).to be_nil
        expect(dns_zone.records_dataset.select_map(:name)).to eq ["new.postgres.ubicloud.com."]
        expect(DB[:seen_dns_records_by_dns_servers].where(dns_server_id: dns_server.id).select_map(:dns_record_id)).to eq dns_zone.records_dataset.select_map(:id)
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).to be_empty
      end

      it "refreshes records while an exited child is still leased and reaps it after lease expiry" do
        child.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}), lease: Time.now + 60)
        runner.dns_zone.dns_servers.first.vms.each do |vm|
          expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands).and_return("OK\n" * 5)
        end

        expect { runner.wait_configure }.to nap(10)
        expect(dns_zone.strand.children_dataset.select_map(:id)).to eq [child.id]
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).to be_empty

        child.update(lease: Time.now - 1)
        expect(dns_zone.strand.reload.unsynchronized_run).to have_attributes(seconds: 5)
        expect(Strand[child.id]).to be_nil
        expect(dns_zone.strand.children_dataset.count).to eq 1
      end

      it "keeps an update arriving during refresh for the next pass" do
        server_vms = runner.dns_zone.dns_servers.first.vms
        expect(server_vms.first.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands) do
          dns_zone.insert_record(record_name: "late.postgres.ubicloud.com", type: "A", ttl: 10, data: "9.10.11.12")
          "OK\n" * 5
        end
        expect(server_vms.last.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands).and_return("OK\n" * 5)

        expect { runner.wait_configure }.to nap(10)
        late_record = dns_zone.records_dataset.first(name: "late.postgres.ubicloud.com.")
        expect(DB[:seen_dns_records_by_dns_servers].where(dns_record_id: late_record.id)).to be_empty
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).not_to be_empty

        next_runner = described_class.new(dns_zone.strand.reload)
        next_runner.dns_zone.dns_servers.first.vms.each do |vm|
          expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: "zone-abort postgres.ubicloud.com\nzone-begin postgres.ubicloud.com\nzone-set postgres.ubicloud.com late.postgres.ubicloud.com. 10 A 9.10.11.12\nzone-commit postgres.ubicloud.com").and_return("OK\n" * 4)
        end
        expect { next_runner.wait_configure }.to nap(10)
        expect(DB[:seen_dns_records_by_dns_servers].where(dns_record_id: late_record.id).count).to eq 1
        expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).to be_empty
        expect(child.refresh.exitval).to be_nil
      end

      [["zone-set", 2], ["zone-unset", 3], ["zone-commit", 4]].each do |command_name, failed_command|
        it "keeps changes pending and retries when #{command_name} is interrupted" do
          replies = Array.new(5, "OK")
          replies[failed_command] = "error: no active transaction"
          expect(sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands).and_return(replies.join("\n"))
          pending_ids = dns_zone.records_dataset.order(:id).select_map(:id)
          queue = runner.configure_queue.dup

          expect {
            DB.transaction(savepoint: true) { runner.wait_configure }
          }.to raise_error(RuntimeError, /Rectify failed.*no active transaction/)

          expect(dns_zone.records_dataset.order(:id).select_map(:id)).to eq pending_ids
          expect(DB[:seen_dns_records_by_dns_servers].where(dns_server_id: dns_server.id).select_map(:dns_record_id)).to eq [old_record.id]
          expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).not_to be_empty
          expect(child.refresh.exitval).to be_nil

          retry_runner = described_class.new(dns_zone.strand.reload)
          retry_runner.dns_zone.dns_servers.first.vms.each do |vm|
            expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands).and_return("OK\n" * 5)
          end
          expect { retry_runner.wait_configure }.to nap(10)

          expect(retry_runner.configure_queue).to eq queue
          expect(child.refresh.exitval).to be_nil
          expect(dns_zone.records_dataset.select_map(:name)).to eq ["new.postgres.ubicloud.com."]
          expect(DB[:seen_dns_records_by_dns_servers].where(dns_server_id: dns_server.id).select_map(:dns_record_id)).to eq dns_zone.records_dataset.select_map(:id)
          expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).to be_empty
        end
      end
    end

    [false, true].each do |deleted|
      it "drains the queue and resumes DNS updates after a queued vm is #{deleted ? "deleted" : "retired"}" do
        vm
        other_vm = create_vm(project_id: prj.id, name: "dns-vm-2")
        Sshable.create_with_id(other_vm, unix_user: "root", host: "test-host-2")
        dns_server.add_vm(other_vm)
        expect { nx.configure }.to hop("wait_configure")
        expect { nx.wait_configure }.to nap(5)

        child = Strand.where(parent_id: dns_zone.id).first
        retired_vm = Vm[child.stack.first["subject_id"]]
        Strand.create_with_id(retired_vm, prog: "Vm::Nexus", label: "wait")
        dns_server.retire_vm(retired_vm.id)
        retired_vm.destroy if deleted
        child.unsynchronized_run
        expect(child.refresh.exitval).to eq({"msg" => "vm retired"})

        expect { nx.wait_configure }.to nap(5)
        child = Strand.where(parent_id: dns_zone.id).first
        worker = Prog::DnsZone::SetupDnsServerVm.new(child)
        expect(worker.vm.id).not_to eq retired_vm.id
        expect(worker.sshable).to receive(:_cmd).with("true").and_return("")
        expect(worker.sshable).to receive(:_cmd).with("sudo tee /etc/knot/knot.conf > /dev/null", stdin: /- domain: "postgres.ubicloud.com."/)
        expect(worker.sshable).to receive(:_cmd).with("sudo -u knot knotc reload")
        result = catch(:prog_return) { worker.configure }
        expect(result).to be_a Prog::Base::Exit
        expect(result.exitval).to eq({"msg" => "configured"})
        child.update(exitval: result.exitval)

        expect { nx.wait_configure }.to hop("wait")
        expect(Strand.where(parent_id: dns_zone.id)).to be_empty
        expect(nx.configure_queue).to be_empty

        dns_zone.insert_record(record_name: "test-pg.postgres.ubicloud.com", type: "A", ttl: 10, data: "1.2.3.4")
        updater = described_class.new(dns_zone.strand)
        expect { updater.wait }.to hop("refresh_dns_servers")
        sshable = updater.dns_zone.dns_servers.first.vms.first.sshable
        expect(sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: "zone-abort postgres.ubicloud.com\nzone-begin postgres.ubicloud.com\nzone-set postgres.ubicloud.com test-pg.postgres.ubicloud.com. 10 A 1.2.3.4\nzone-commit postgres.ubicloud.com").and_return("OK\nOK\nOK\nOK")
        expect { updater.refresh_dns_servers }.to hop("purge_obsolete_records")
        expect(DB[:seen_dns_records_by_dns_servers].where(dns_server_id: dns_server.id).select_map(:dns_record_id)).to eq dns_zone.records_dataset.select_map(:id)
      end
    end

    it "buds configure for one vm at a time and hops to wait when the queue drains" do
      vm
      other_vm = create_vm(project_id: prj.id, name: "dns-vm-2")
      Sshable.create_with_id(other_vm, unix_user: "root", host: "test-host-2")
      dns_server.add_vm(other_vm)
      expect { nx.configure }.to hop("wait_configure")

      expect { nx.wait_configure }.to nap(5)
      children = Strand.where(parent_id: dns_zone.id).all
      expect(children.map(&:prog)).to eq ["DnsZone::SetupDnsServerVm"]
      expect(children.map(&:label)).to eq ["configure"]
      first_frame = children.first.stack.first
      expect([vm.id, other_vm.id]).to include first_frame["subject_id"]
      expect(first_frame["dns_server_id"]).to eq dns_server.id

      expect { nx.wait_configure }.to nap(10)
      expect(Strand.where(parent_id: dns_zone.id).count).to eq 1

      children.first.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}))
      expect { nx.wait_configure }.to nap(5)
      children = Strand.where(parent_id: dns_zone.id).all
      expect(children.map { it.stack.first["subject_id"] }).to eq [vm.id, other_vm.id] - [first_frame["subject_id"]]

      children.first.update(exitval: Sequel.pg_jsonb_wrap({"msg" => "configured"}))
      expect { nx.wait_configure }.to hop("wait")
      expect(Strand.where(parent_id: dns_zone.id)).to be_empty
    end
  end

  describe "#refresh_dns_servers" do
    before do
      vm
      r1 = DnsRecord.create(name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r2 = DnsRecord.create(name: "test-pg-2.postgres.ubicloud.com.", type: "A", ttl: 10, data: "5.6.7.8", dns_zone_id: dns_zone.id)
      r3 = DnsRecord.create(name: "test-pg-3.postgres.ubicloud.com.", type: "A", ttl: 10, data: "9.10.11.12", tombstoned: true, dns_zone_id: dns_zone.id)

      dns_zone.add_record(r1)
      dns_zone.add_record(r2)
      dns_zone.add_record(r3)

      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r1.id, dns_server_id: dns_server.id)
    end

    let(:sshable) { nx.dns_zone.dns_servers.first.vms.first.sshable }

    it "yields to requested configuration without losing pending record updates" do
      nx.incr_configure
      nx.incr_refresh_dns_servers

      expect { nx.refresh_dns_servers }.to hop("wait")

      expect(Semaphore.where(strand_id: dns_zone.id, name: "configure")).not_to be_empty
      expect(Semaphore.where(strand_id: dns_zone.id, name: "refresh_dns_servers")).not_to be_empty
    end

    it "does not push anything if there is no unseen records" do
      DB[:seen_dns_records_by_dns_servers].insert(DB[:dns_record].select(:id, dns_server.id))

      expect(sshable).not_to receive(:_cmd)
      expect { nx.refresh_dns_servers }.to hop("purge_obsolete_records")
    end

    it "gathers unseen records for each dns server and pushes them to dns servers" do
      expected_commands = <<COMMANDS
zone-abort postgres.ubicloud.com
zone-begin postgres.ubicloud.com
zone-set postgres.ubicloud.com test-pg-2.postgres.ubicloud.com. 10 A 5.6.7.8
zone-unset postgres.ubicloud.com test-pg-3.postgres.ubicloud.com. 10 A 9.10.11.12
zone-commit postgres.ubicloud.com
COMMANDS

      expect(sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: expected_commands.chomp).and_return("OK\nOK\nOK\nOK\nOK")
      DnsRecord.where(data: "5.6.7.8").update(created_at: Time.now - 60)
      expect { nx.refresh_dns_servers }.to hop("purge_obsolete_records")
    end

    it "ignores unimportant errors" do
      expect(sshable).to receive(:_cmd).and_return("no active transaction\nOK\nno such record in zone found\nsuch record already exists in zone\nOK\n")
      expect { nx.refresh_dns_servers }.to hop("purge_obsolete_records")
    end

    it "raises an exception for unexpected failures" do
      expect(sshable).to receive(:_cmd).and_return("error in zone-abort\nOK\nOK\nOK\nOK")

      expect {
        nx.refresh_dns_servers
      }.to raise_error RuntimeError, "Rectify failed on #{dns_server}. Command: zone-abort postgres.ubicloud.com. Output: error in zone-abort"
    end
  end

  describe "#purge_obsolete_records" do
    it "deletes obsoleted records, seen or unseen" do
      r1 = DnsRecord.create(created_at: Time.now - 1, name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r2 = DnsRecord.create(created_at: Time.now, name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r3 = DnsRecord.create(created_at: Time.now + 1, name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)

      dns_zone.add_record(r1)
      dns_zone.add_record(r2)
      dns_zone.add_record(r3)

      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r1.id, dns_server_id: dns_server.id)
      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r3.id, dns_server_id: dns_server.id)

      expect { nx.purge_obsolete_records }.to hop("wait")
      expect(dns_zone.reload.records.count).to eq(1)
      expect(DB[:seen_dns_records_by_dns_servers].all.count).to eq(1)
    end

    it "deletes seen tombstoned records" do
      r1 = DnsRecord.create(name: "test-pg-1.postgres.ubicloud.com.", type: "A", ttl: 10, data: "1.2.3.4", dns_zone_id: dns_zone.id)
      r2 = DnsRecord.create(name: "test-pg-2.postgres.ubicloud.com.", type: "A", ttl: 10, data: "5.6.7.8", tombstoned: true, dns_zone_id: dns_zone.id)
      r3 = DnsRecord.create(name: "test-pg-3.postgres.ubicloud.com.", type: "A", ttl: 10, data: "9.10.11.12", tombstoned: true, dns_zone_id: dns_zone.id)

      dns_zone.add_record(r1)
      dns_zone.add_record(r2)
      dns_zone.add_record(r3)

      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r1.id, dns_server_id: dns_server.id)
      DB[:seen_dns_records_by_dns_servers].insert(dns_record_id: r2.id, dns_server_id: dns_server.id)

      expect { nx.purge_obsolete_records }.to hop("wait")
      expect(dns_zone.reload.records.count).to eq(2)
      expect(DB[:seen_dns_records_by_dns_servers].all.count).to eq(1)
    end
  end
end
