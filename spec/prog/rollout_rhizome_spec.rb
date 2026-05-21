# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RolloutRhizome do
  subject(:nx) { described_class.new(st) }

  let(:st) {
    vm_hosts
    described_class.assemble(vm_project_id: project_id)
  }
  let(:project_id) { Project.create(name: "RolloutRhizomeTest").id }

  let(:fsn1_host) { create_vm_host(created_at: Time.utc(2024, 1, 1), location_id: Location::HETZNER_FSN1_ID) }
  let(:hel1_host) { create_vm_host(created_at: Time.utc(2024, 1, 2), location_id: Location::HETZNER_HEL1_ID) }
  let(:wdc2_host) { create_vm_host(created_at: Time.utc(2024, 1, 3), location_id: Location::LEASEWEB_WDC02_ID) }
  let(:ghr_hosts) {
    [
      create_vm_host(created_at: Time.utc(2024, 1, 4), arch: "arm64", location_id: Location::GITHUB_RUNNERS_ID),
      create_vm_host(created_at: Time.utc(2024, 1, 5), arch: "arm64", location_id: Location::GITHUB_RUNNERS_ID),
      create_vm_host(created_at: Time.utc(2024, 1, 6), location_id: Location::GITHUB_RUNNERS_ID),
      create_vm_host(created_at: Time.utc(2024, 1, 7), location_id: Location::GITHUB_RUNNERS_ID),
      create_vm_host(created_at: Time.utc(2024, 1, 8), location_id: Location::GITHUB_RUNNERS_ID),
    ]
  }
  let(:vm_hosts) {
    [
      fsn1_host,
      hel1_host,
      wdc2_host,
      *ghr_hosts,
    ]
  }

  def reload_frame
    st.reload.stack.first
  end

  describe ".assemble" do
    it "creates strand with hosts to rollout to" do
      expect(st.label).to eq("start")
      expect(st.prog).to eq("RolloutRhizome")

      frame = st.stack.first
      expect(frame["vm_project_id"]).to eq(project_id)
      expect(frame["initial_host_ids"]).to eq([fsn1_host.id, wdc2_host.id])
      expect(frame["completed"]).to eq([])

      remaining_host_ids = frame["remaining_host_ids"]
      expect(remaining_host_ids).to include(hel1_host.id)
      expect(remaining_host_ids.size).to eq 2
      remaining_host_ids.delete(hel1_host.id)

      expect(ghr_hosts.map(&:id).sort!).to eq((frame["initial_github_runner_host_ids"] << remaining_host_ids.first).sort!)
    end

    it "respects Config.rollouts_project_id" do
      expect(Config).to receive(:rollouts_project_id).and_return(project_id)
      st = described_class.assemble
      expect(st.label).to eq("start")
      expect(st.prog).to eq("RolloutRhizome")

      frame = st.stack.first
      expect(frame["vm_project_id"]).to eq(project_id)
      expect(frame["initial_host_ids"]).to eq([])
      expect(frame["initial_github_runner_host_ids"]).to eq([])
      expect(frame["remaining_host_ids"]).to eq([])
      expect(frame["completed"]).to eq([])
    end
  end

  describe "#before_run" do
    it "naps when pause semaphore is set" do
      nx.incr_pause
      expect { nx.before_run }.to nap(60 * 60)
    end
  end

  describe "#start" do
    it "creates InstallRhizome strands and hops" do
      ds = Strand.where(prog: "InstallRhizome", label: "start")
      expect { nx.start }.to hop("wait_initial_rhizome_install")
        .and change { ds.count }.from(0).to(2)
      subject_ids = ds.select_map(:stack).map { it[0]["subject_id"] }
      expect(subject_ids.sort!).to eq([fsn1_host.id, wdc2_host.id].sort!)
    end
  end

  describe "#wait_initial_rhizome_install" do
    it "naps if there are child strands" do
      Strand.create(prog: "InstallRhizome", label: "start", parent_id: st.id, lease: Time.now + 100)
      expect { nx.wait_initial_rhizome_install }.to nap(120)
    end

    it "hops if there are no child strands" do
      expect { nx.wait_initial_rhizome_install }.to hop("setup_vms_on_initial_hosts")
    end
  end

  describe "#setup_vms_on_initial_hosts" do
    it "creates vms and hops" do
      strand_ds = Strand.where(prog: "Vm::Metal::Nexus", label: "start")
      expect { nx.setup_vms_on_initial_hosts }.to hop("wait_vms_on_initial_hosts")
        .and change { Vm.where(:ip4_enabled).count }.from(0).to(2)
        .and change { strand_ds.count }.from(0).to(2)
      SshKey.from_binary(Base64.strict_decode64(st.stack[0]["initial_vms_keypair"]))
      expect(Vm.select_order_map(:id)).to eq st.stack[0]["initial_vm_ids"].sort!
    end
  end

  describe "#wait_vms_on_initial_hosts" do
    before do
      refresh_frame(nx, new_values: {"initial_vm_ids" => Array.new(2) { Prog::Vm::Nexus.assemble("a a", project_id).id }})
    end

    it "naps if all expected vm strands are not in wait state" do
      expect { nx.wait_vms_on_initial_hosts }.to nap(30)
    end

    it "hops if all expected vm strands are in wait state" do
      Strand.where(prog: "Vm::Metal::Nexus", label: "start").update(label: "wait")
      expect { nx.wait_vms_on_initial_hosts }.to hop("check_vms_on_initial_hosts")
    end
  end

  describe "#check_vms_on_initial_hosts" do
    it "checks vms and hops" do
      # Setup vms
      expect { nx.setup_vms_on_initial_hosts }.to hop("wait_vms_on_initial_hosts")
      refresh_frame(nx)

      vms = Vm.eager(:location).all.each_with_index do |vm, i|
        AssignedVmAddress.create(ip: "10.#{i}.0.1", dst_vm_id: vm.id)
      end
      ips = vms.map(&:ip4_string)
      expect(ips.all?).to be true
      ssh_key = SshKey.from_binary(Base64.strict_decode64(st.stack[0]["initial_vms_keypair"]))

      called = 0
      expect(Sshable).to receive(:new_with_id) do |host:, raw_private_key_1:, unix_user:|
        expect(ips).to include(host)
        expect(raw_private_key_1).to eq ssh_key.keypair
        expect(unix_user).to eq "rhizome"
        sshable = Sshable.new
        expect(sshable).to receive(:_cmd).with("sudo apt update && sudo apt install -y fio")
        expect(sshable).to receive(:_cmd).with("fio --version")
        called += 1
        sshable
      end.twice

      expect { nx.check_vms_on_initial_hosts }.to hop("destroy_vms_on_initial_hosts")
        .and change { called }.from(0).to(2)
    end
  end

  describe "#destroy_vms_on_initial_hosts" do
    it "destroys vms and hops" do
      # Setup vms
      expect { nx.setup_vms_on_initial_hosts }.to hop("wait_vms_on_initial_hosts")
      refresh_frame(nx)

      initial_vm_ids = st.stack[0]["initial_vm_ids"]
      expect { nx.destroy_vms_on_initial_hosts }.to hop("install_on_initial_github_runners_hosts")
        .and change { Semaphore.where(strand_id: initial_vm_ids, name: "destroy").count }.from(0).to(2)
      expect(st.reload.stack[0].has_key?("initial_vm_ids")).to be false
      expect(st.stack[0].has_key?("initial_vms_keypair")).to be false
    end

    it "skips github runner testing if there are no github runners" do
      refresh_frame(nx, new_values: {"initial_github_runner_host_ids" => [], "initial_vm_ids" => []})
      expect { nx.destroy_vms_on_initial_hosts }.to hop("rollout_next")
      expect(st.reload.stack[0]["next_runner_time"]).to be_within(5).of(Time.now.to_i)
    end
  end

  describe "#install_on_initial_github_runners_hosts" do
    it "creates InstallRhizome strands and hops" do
      ds = Strand.where(prog: "InstallRhizome", label: "start")
      expect { nx.install_on_initial_github_runners_hosts }.to hop("wait_initial_github_runners_rhizome_install")
        .and change { ds.count }.from(0).to(4)
      ghr_ids = ghr_hosts.map(&:id)
      ds.select_map(:stack).each do
        expect(ghr_ids).to include(it[0]["subject_id"])
      end
      expect(st.reload.stack[0]["monitor_github_runners_until"]).to be_within(5).of(Time.now.to_i + 45 * 60)
    end
  end

  describe "#wait_initial_github_runners_rhizome_install" do
    it "naps if there are child strands" do
      Strand.create(prog: "InstallRhizome", label: "start", parent_id: st.id, lease: Time.now + 100)
      expect { nx.wait_initial_github_runners_rhizome_install }.to nap(120)
    end

    it "hops if there are no child strands" do
      expect { nx.wait_initial_github_runners_rhizome_install }.to hop("monitor_github_runners")
    end
  end

  describe "#monitor_github_runners" do
    it "naps if we haven't monitored github runners long enough" do
      refresh_frame(nx, new_values: {"monitor_github_runners_until" => Time.now.to_i + 10})
      expect { nx.monitor_github_runners }.to nap(5...15)
    end

    it "hops if github_runners_work semaphore is set" do
      refresh_frame(nx, new_values: {"monitor_github_runners_until" => Time.now.to_i - 10})
      nx.incr_github_runners_work
      expect { nx.monitor_github_runners }.to hop("rollout_next")
      expect(st.reload.stack[0]["next_runner_time"]).to be_within(5).of(Time.now.to_i)
    end

    it "naps otherwise" do
      refresh_frame(nx, new_values: {"monitor_github_runners_until" => Time.now.to_i - 10})
      expect { nx.monitor_github_runners }.to nap(60 * 60)
    end
  end

  describe "#wait" do
    it "naps if there are running child strands" do
      Strand.create(prog: "InstallRhizome", label: "start", parent_id: st.id, lease: Time.now + 100)
      expect { nx.wait }.to nap(120)
    end

    it "hops if there are no running child strands" do
      vm_host_id = VmHost.generate_uuid
      Strand.create(prog: "InstallRhizome", label: "start", parent_id: st.id, exitval: {msg: "installed rhizome"}, stack: [{"subject_id" => vm_host_id}])
      expect { nx.wait }.to hop("rollout_next")
      expect(st.reload.stack[0]["next_runner_time"]).to be_within(5).of(Time.now.to_i + 30)
      expect(st.stack[0]["completed"]).to eq [vm_host_id]
    end
  end

  describe "#rollout_next" do
    it "pops if there are no remaining hosts" do
      refresh_frame(nx, new_values: {"next_runner_time" => Time.now.to_i - 10, "remaining_host_ids" => []})
      expect { nx.rollout_next }.to hop("destroy")
    end

    it "naps if it is not yet next_runner_time" do
      refresh_frame(nx, new_values: {"next_runner_time" => Time.now.to_i + 10})
      expect { nx.rollout_next }.to nap(5...15)
    end

    it "creates InstallRhizome strand and hops" do
      refresh_frame(nx, new_values: {"next_runner_time" => Time.now.to_i - 10})
      ds = Strand.where(prog: "InstallRhizome", label: "start")
      next_host_id = st.stack[0]["remaining_host_ids"].first
      expect { nx.rollout_next }.to hop("wait")
        .and change { ds.count }.from(0).to(1)
        .and change { st.reload.stack[0]["remaining_host_ids"].size }.from(2).to(1)
      expect(ds.get(:stack)[0]["subject_id"]).to eq next_host_id
    end
  end

  describe "#destroy" do
    it "exits if destroy semaphore is set" do
      nx.incr_destroy
      expect { nx.destroy }.to exit("msg" => "rollout completed")
    end

    it "naps otherwise" do
      expect { nx.destroy }.to nap(60 * 60 * 24 * 365)
    end
  end
end
