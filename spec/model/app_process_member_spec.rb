# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AppProcessMember do
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

  let(:vm) { create_vm(project_id: project.id, location_id: location.id) }

  let(:member) do
    AppProcessMember.create(
      app_process_id: ap.id,
      vm_id: vm.id,
      ordinal: 0,
      state: "active"
    )
  end

  describe "associations" do
    it "belongs to app_process" do
      expect(member.app_process.id).to eq(ap.id)
    end

    it "belongs to vm" do
      expect(member.vm.id).to eq(vm.id)
    end

    it "has many app_member_inits" do
      tag = InitScriptTag.create(project_id: project.id, name: "s", version: 1, init_script: "#!/bin/bash")
      AppMemberInit.create(app_process_member_id: member.id, init_script_tag_id: tag.id)
      expect(member.app_member_inits.length).to eq(1)
    end
  end

  describe "uniqueness constraints" do
    it "enforces unique (app_process_id, ordinal)" do
      member
      vm2 = create_vm(project_id: project.id, location_id: location.id, name: "test-vm-2")
      expect {
        AppProcessMember.create(app_process_id: ap.id, vm_id: vm2.id, ordinal: 0, state: "active")
      }.to raise_error(Sequel::ValidationFailed, /already taken/)
    end

    it "enforces unique vm_id" do
      member
      ap2 = AppProcess.create(
        group_name: "myapp", name: "wkr",
        project_id: project.id, location_id: location.id
      )
      expect {
        AppProcessMember.create(app_process_id: ap2.id, vm_id: vm.id, ordinal: 0, state: "active")
      }.to raise_error(Sequel::ValidationFailed, /already taken/)
    end
  end

  describe "FK cascade on VM deletion" do
    it "cascades member deletion when VM is deleted" do
      member_id = member.id
      vm.destroy
      expect(AppProcessMember[member_id]).to be_nil
    end
  end
end

RSpec.describe AppMemberInit do
  let(:project) { Project.create(name: "test-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:ap) do
    AppProcess.create(
      group_name: "myapp", name: "web",
      project_id: project.id, location_id: location.id
    )
  end

  let(:vm) { create_vm(project_id: project.id, location_id: location.id) }

  let(:member) do
    AppProcessMember.create(app_process_id: ap.id, vm_id: vm.id, ordinal: 0, state: "active")
  end

  let(:tag) do
    InitScriptTag.create(project_id: project.id, name: "setup", version: 1, init_script: "#!/bin/bash")
  end

  let(:ami) do
    AppMemberInit.create(app_process_member_id: member.id, init_script_tag_id: tag.id)
  end

  describe "associations" do
    it "belongs to app_process_member" do
      expect(ami.app_process_member.id).to eq(member.id)
    end

    it "belongs to init_script_tag" do
      expect(ami.init_script_tag.id).to eq(tag.id)
    end
  end

  describe "uniqueness constraint" do
    it "enforces unique (app_process_member_id, init_script_tag_id)" do
      ami
      expect {
        AppMemberInit.create(app_process_member_id: member.id, init_script_tag_id: tag.id)
      }.to raise_error(Sequel::ValidationFailed, /already taken/)
    end
  end

  describe "FK cascade on member deletion" do
    it "cascades deletion when member is deleted" do
      ami_id = ami.id
      member.destroy
      expect(AppMemberInit[ami_id]).to be_nil
    end
  end
end

RSpec.describe AppProcessInit do
  let(:project) { Project.create(name: "test-project") }
  let(:location) { Location[Location::HETZNER_FSN1_ID] }

  let(:ap) do
    AppProcess.create(
      group_name: "myapp", name: "web",
      project_id: project.id, location_id: location.id
    )
  end

  let(:tag) do
    InitScriptTag.create(project_id: project.id, name: "deploy", version: 1, init_script: "#!/bin/bash")
  end

  let(:api) do
    AppProcessInit.create(app_process_id: ap.id, init_script_tag_id: tag.id, ordinal: 0)
  end

  describe "associations" do
    it "belongs to app_process" do
      expect(api.app_process.id).to eq(ap.id)
    end

    it "belongs to init_script_tag" do
      expect(api.init_script_tag.id).to eq(tag.id)
    end
  end

  describe "uniqueness constraints" do
    it "enforces unique (app_process_id, init_script_tag_id)" do
      api
      expect {
        AppProcessInit.create(app_process_id: ap.id, init_script_tag_id: tag.id, ordinal: 1)
      }.to raise_error(Sequel::ValidationFailed, /already taken/)
    end

    it "enforces unique (app_process_id, ordinal)" do
      api
      tag2 = InitScriptTag.create(project_id: project.id, name: "other", version: 1, init_script: "#!/bin/bash")
      expect {
        AppProcessInit.create(app_process_id: ap.id, init_script_tag_id: tag2.id, ordinal: 0)
      }.to raise_error(Sequel::ValidationFailed, /already taken/)
    end
  end
end

RSpec.describe AppRelease do
  let(:project) { Project.create(name: "test-project") }

  let(:release) do
    AppRelease.create(
      project_id: project.id,
      group_name: "myapp",
      release_number: 1,
      action: "set"
    )
  end

  describe "associations" do
    it "belongs to project" do
      expect(release.project.id).to eq(project.id)
    end

    it "has many app_release_snapshots" do
      ap = AppProcess.create(
        group_name: "myapp", name: "web",
        project_id: project.id, location_id: Location::HETZNER_FSN1_ID
      )
      AppReleaseSnapshot.create(app_release_id: release.id, app_process_id: ap.id, deploy_ordinal: 1)
      expect(release.app_release_snapshots.length).to eq(1)
    end
  end

  describe "uniqueness constraint" do
    it "enforces unique (project_id, group_name, release_number)" do
      release
      expect {
        AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 1, action: "set")
      }.to raise_error(Sequel::ValidationFailed, /already taken/)
    end
  end
end

RSpec.describe AppReleaseSnapshot do
  let(:project) { Project.create(name: "test-project") }

  let(:ap) do
    AppProcess.create(
      group_name: "myapp", name: "web",
      project_id: project.id, location_id: Location::HETZNER_FSN1_ID
    )
  end

  let(:release) do
    AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 1, action: "set")
  end

  let(:snapshot) do
    AppReleaseSnapshot.create(app_release_id: release.id, app_process_id: ap.id, deploy_ordinal: 1)
  end

  describe "associations" do
    it "belongs to app_release" do
      expect(snapshot.app_release.id).to eq(release.id)
    end

    it "belongs to app_process" do
      expect(snapshot.app_process.id).to eq(ap.id)
    end

    it "has many app_release_snapshot_inits" do
      tag = InitScriptTag.create(project_id: project.id, name: "s", version: 1, init_script: "#!/bin/bash")
      AppReleaseSnapshotInit.create(app_release_snapshot_id: snapshot.id, init_script_tag_id: tag.id)
      expect(snapshot.app_release_snapshot_inits.length).to eq(1)
    end
  end
end

RSpec.describe AppReleaseSnapshotInit do
  let(:project) { Project.create(name: "test-project") }

  let(:ap) do
    AppProcess.create(
      group_name: "myapp", name: "web",
      project_id: project.id, location_id: Location::HETZNER_FSN1_ID
    )
  end

  let(:release) do
    AppRelease.create(project_id: project.id, group_name: "myapp", release_number: 1, action: "set")
  end

  let(:snapshot) do
    AppReleaseSnapshot.create(app_release_id: release.id, app_process_id: ap.id, deploy_ordinal: 1)
  end

  let(:tag) do
    InitScriptTag.create(project_id: project.id, name: "deploy", version: 1, init_script: "#!/bin/bash")
  end

  let(:arsi) do
    AppReleaseSnapshotInit.create(app_release_snapshot_id: snapshot.id, init_script_tag_id: tag.id)
  end

  describe "associations" do
    it "belongs to app_release_snapshot" do
      expect(arsi.app_release_snapshot.id).to eq(snapshot.id)
    end

    it "belongs to init_script_tag" do
      expect(arsi.init_script_tag.id).to eq(tag.id)
    end
  end

  describe "uniqueness constraint" do
    it "enforces unique (app_release_snapshot_id, init_script_tag_id)" do
      arsi
      expect {
        AppReleaseSnapshotInit.create(app_release_snapshot_id: snapshot.id, init_script_tag_id: tag.id)
      }.to raise_error(Sequel::ValidationFailed, /already taken/)
    end
  end
end
