# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AppProcess do
  let(:project) { Project.create(name: "test-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:ps) do
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps", location_id: location.id).subject
  end

  let(:ap) do
    AppProcess.create(
      group_name: "myapp",
      name: "web",
      project_id: project.id,
      location_id: location.id,
      private_subnet_id: ps.id
    )
  end

  describe "#flat_name" do
    it "returns group_name-name" do
      expect(ap.flat_name).to eq("myapp-web")
    end
  end

  describe "#display_name" do
    it "returns group_name/name" do
      expect(ap.display_name).to eq("myapp/web")
    end
  end

  describe "#path" do
    it "returns location-based path" do
      expect(ap.path).to eq("/location/#{location.display_name}/app/myapp-web")
    end
  end

  describe "#deployment_managed?" do
    it "returns false when umi_id is nil" do
      expect(ap.deployment_managed?).to be(false)
    end

    it "returns true when umi_id is set" do
      ap.update(umi_id: SecureRandom.uuid, umi_ref: "ubuntu-noble")
      expect(ap.deployment_managed?).to be(true)
    end
  end

  describe "#next_ordinal" do
    it "returns 0 when there are no members" do
      expect(ap.next_ordinal).to eq(0)
    end

    it "returns one more than the highest ordinal" do
      vm1 = create_vm(project_id: project.id, location_id: location.id, name: "test-vm-1")
      vm2 = create_vm(project_id: project.id, location_id: location.id, name: "test-vm-2")
      AppProcessMember.create(app_process_id: ap.id, vm_id: vm1.id, ordinal: 0, state: "active")
      AppProcessMember.create(app_process_id: ap.id, vm_id: vm2.id, ordinal: 3, state: "active")
      expect(ap.next_ordinal).to eq(4)
    end
  end

  describe "#vm_count" do
    it "returns 0 when there are no members" do
      expect(ap.vm_count).to eq(0)
    end

    it "returns the count of members" do
      vm = create_vm(project_id: project.id, location_id: location.id)
      AppProcessMember.create(app_process_id: ap.id, vm_id: vm.id, ordinal: 0, state: "active")
      expect(ap.vm_count).to eq(1)
    end
  end

  describe "#active_members" do
    it "returns only active members" do
      vm1 = create_vm(project_id: project.id, location_id: location.id, name: "test-vm-1")
      vm2 = create_vm(project_id: project.id, location_id: location.id, name: "test-vm-2")
      AppProcessMember.create(app_process_id: ap.id, vm_id: vm1.id, ordinal: 0, state: "active")
      AppProcessMember.create(app_process_id: ap.id, vm_id: vm2.id, ordinal: 1, state: "draining")
      expect(ap.active_members.count).to eq(1)
    end
  end

  describe "#load_balancer" do
    it "returns nil when no subnet" do
      ap_no_sub = AppProcess.create(
        group_name: "myapp", name: "nosub",
        project_id: project.id, location_id: location.id,
        private_subnet_id: nil
      )
      expect(ap_no_sub.load_balancer).to be_nil
    end

    it "returns nil when no LB on subnet" do
      expect(ap.load_balancer).to be_nil
    end

    it "returns the LB on the subnet" do
      lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 443, dst_port: 3000).subject
      expect(ap.load_balancer.id).to eq(lb.id)
    end
  end

  describe "#has_lb?" do
    it "returns false when no LB" do
      expect(ap.has_lb?).to be(false)
    end

    it "returns true when LB exists" do
      Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 443, dst_port: 3000)
      expect(ap.has_lb?).to be(true)
    end
  end

  describe "#group_processes" do
    it "returns all processes in the same group" do
      ap
      AppProcess.create(
        group_name: "myapp", name: "wkr",
        project_id: project.id, location_id: location.id
      )
      # Different group, should not be included
      AppProcess.create(
        group_name: "other", name: "web",
        project_id: project.id, location_id: location.id
      )

      group = ap.group_processes
      expect(group.map(&:name)).to contain_exactly("web", "wkr")
    end
  end

  describe "#group_subnet_ids" do
    it "returns subnet ids for the group" do
      ap
      ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-ps-2", location_id: location.id).subject
      AppProcess.create(
        group_name: "myapp", name: "wkr",
        project_id: project.id, location_id: location.id,
        private_subnet_id: ps2.id
      )

      ids = ap.group_subnet_ids
      expect(ids).to contain_exactly(ps.id, ps2.id)
    end

    it "excludes processes with nil subnet" do
      ap
      AppProcess.create(
        group_name: "myapp", name: "nosub",
        project_id: project.id, location_id: location.id,
        private_subnet_id: nil
      )
      expect(ap.group_subnet_ids).to eq([ps.id])
    end
  end

  describe "#external_connected_subnet_names" do
    it "returns empty when no subnet" do
      ap_no_sub = AppProcess.create(
        group_name: "myapp", name: "nosub",
        project_id: project.id, location_id: location.id,
        private_subnet_id: nil
      )
      expect(ap_no_sub.external_connected_subnet_names).to eq([])
    end

    it "returns names of external connected subnets" do
      external_ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "ext-db", location_id: location.id).subject
      ps.connect_subnet(external_ps)
      expect(ap.external_connected_subnet_names).to include("ext-db")
    end

    it "excludes subnets owned by the same group" do
      ps2 = Prog::Vnet::SubnetNexus.assemble(project.id, name: "group-wkr", location_id: location.id).subject
      AppProcess.create(
        group_name: "myapp", name: "wkr",
        project_id: project.id, location_id: location.id,
        private_subnet_id: ps2.id
      )
      ps.connect_subnet(ps2)
      expect(ap.external_connected_subnet_names).not_to include("group-wkr")
    end
  end

  describe "#latest_release_number" do
    it "returns nil when no releases" do
      expect(ap.latest_release_number).to be_nil
    end

    it "returns the highest release number for the group" do
      AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 1, action: "set")
      AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 3, action: "set")
      AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 2, action: "set")
      expect(ap.latest_release_number).to eq(3)
    end

    it "does not include releases from other groups" do
      AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 5, action: "set")
      AppRelease.create(project_id: project.id, group_name: "other", release_number: 10, action: "set")
      expect(ap.latest_release_number).to eq(5)
    end
  end

  describe "#before_destroy" do
    it "destroys associated inits, members, and snapshots" do
      vm = create_vm(project_id: project.id, location_id: location.id)
      member = AppProcessMember.create(app_process_id: ap.id, vm_id: vm.id, ordinal: 0, state: "active")

      tag = InitScriptTag.create(project_id: project.id, name: "s", version: 1, init_script: "#!/bin/bash")
      AppProcessInit.create(app_process_id: ap.id, init_script_tag_id: tag.id, ordinal: 0)
      AppMemberInit.create(app_process_member_id: member.id, init_script_tag_id: tag.id)

      release = AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 1, action: "set")
      AppReleaseSnapshot.create(app_release_id: release.id, app_process_id: ap.id, deploy_ordinal: 1)

      ap.destroy

      expect(AppProcessInit.where(app_process_id: ap.id).count).to eq(0)
      expect(AppProcessMember.where(app_process_id: ap.id).count).to eq(0)
      expect(AppReleaseSnapshot.where(app_process_id: ap.id).count).to eq(0)
    end
  end

  describe "associations" do
    it "belongs to project" do
      expect(ap.project.id).to eq(project.id)
    end

    it "belongs to location" do
      expect(ap.location.id).to eq(location.id)
    end

    it "belongs to private_subnet" do
      expect(ap.private_subnet.id).to eq(ps.id)
    end

    it "has many app_process_members" do
      vm = create_vm(project_id: project.id, location_id: location.id)
      AppProcessMember.create(app_process_id: ap.id, vm_id: vm.id, ordinal: 0, state: "active")
      expect(ap.app_process_members.length).to eq(1)
    end

    it "has many app_process_inits" do
      tag = InitScriptTag.create(project_id: project.id, name: "s", version: 1, init_script: "#!/bin/bash")
      AppProcessInit.create(app_process_id: ap.id, init_script_tag_id: tag.id, ordinal: 0)
      expect(ap.app_process_inits.length).to eq(1)
    end
  end

  describe "#display_location" do
    it "returns the location display name" do
      expect(ap.display_location).to eq(location.display_name)
    end
  end
end
