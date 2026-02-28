# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::App::Homeostasis do
  subject(:nx) { described_class.new(st) }

  let(:project) { Project.create(name: "test-project") }

  let(:st) {
    Strand.create(id: Strand.generate_uuid, prog: "App::Homeostasis", label: "check")
  }

  def create_machine_image(name:, project_id:, location_id:)
    mi = MachineImage.create(
      name: name,
      description: "test image",
      project_id: project_id,
      location_id: location_id,
      arch: "x64"
    )
    ver = MachineImageVersion.create(
      machine_image_id: mi.id,
      version: "1",
      state: "available",
      size_gib: 10,
      s3_bucket: "test-bucket",
      s3_prefix: "images/test/",
      s3_endpoint: "https://r2.example.com"
    )
    ver.activate!
    [mi, ver]
  end

  describe "#check" do
    it "creates replacement VMs when actual < desired with complete template" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-sub", location_id: Location::HETZNER_FSN1_ID).subject
      _mi, miv = create_machine_image(name: "myapp@1.0", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)

      ap = AppProcess.create(
        group_name: "myapp",
        name: "web",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        umi_id: SecureRandom.uuid,
        umi_ref: "myapp@1.0",
        private_subnet_id: ps.id,
        desired_count: 3
      )

      # Create 2 existing members (gap of 1)
      2.times do |i|
        vm = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID, name: "myapp-web-#{i}")
        AppProcessMember.create(
          app_process_id: ap.id,
          vm_id: vm.id,
          ordinal: i,
          state: "active"
        )
      end

      expect(ap.app_process_members_dataset.count).to eq(2)

      expect(Prog::Vm::Nexus).to receive(:assemble_with_sshable).with(
        project.id,
        hash_including(
          name: "myapp-web-2",
          size: "standard-2",
          location_id: Location::HETZNER_FSN1_ID,
          private_subnet_id: ps.id,
          storage_volumes: [{machine_image_version_id: miv.id}],
          enable_ip4: false
        )
      ).and_return(
        instance_double(Strand, subject: create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID))
      )

      expect { nx.check }.to hop("wait")

      # Should have created 1 new member
      expect(ap.app_process_members_dataset.count).to eq(3)
    end

    it "skips processes with incomplete template (no umi_ref)" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-sub-2", location_id: Location::HETZNER_FSN1_ID).subject

      AppProcess.create(
        group_name: "myapp",
        name: "wkr",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        umi_id: nil,
        umi_ref: nil,
        private_subnet_id: ps.id,
        desired_count: 2
      )

      expect(Prog::Vm::Nexus).not_to receive(:assemble_with_sshable)

      expect { nx.check }.to hop("wait")
    end

    it "skips processes where actual >= desired" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-sub-3", location_id: Location::HETZNER_FSN1_ID).subject
      create_machine_image(name: "myapp@1.0", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)

      ap = AppProcess.create(
        group_name: "myapp",
        name: "api",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        umi_id: SecureRandom.uuid,
        umi_ref: "myapp@1.0",
        private_subnet_id: ps.id,
        desired_count: 1
      )

      vm = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
      AppProcessMember.create(
        app_process_id: ap.id,
        vm_id: vm.id,
        ordinal: 0,
        state: "active"
      )

      expect(Prog::Vm::Nexus).not_to receive(:assemble_with_sshable)

      expect { nx.check }.to hop("wait")
    end

    it "skips processes with no subnet" do
      AppProcess.create(
        group_name: "myapp",
        name: "orphan",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        umi_id: SecureRandom.uuid,
        umi_ref: "myapp@1.0",
        private_subnet_id: nil,
        desired_count: 2
      )

      expect(Prog::Vm::Nexus).not_to receive(:assemble_with_sshable)

      expect { nx.check }.to hop("wait")
    end

    it "skips processes with no vm_size" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-sub-5", location_id: Location::HETZNER_FSN1_ID).subject

      AppProcess.create(
        group_name: "myapp",
        name: "nosiz",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: nil,
        umi_id: SecureRandom.uuid,
        umi_ref: "myapp@1.0",
        private_subnet_id: ps.id,
        desired_count: 2
      )

      expect(Prog::Vm::Nexus).not_to receive(:assemble_with_sshable)

      expect { nx.check }.to hop("wait")
    end

    it "copies init tags to new members" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-sub-6", location_id: Location::HETZNER_FSN1_ID).subject
      create_machine_image(name: "myapp@1.0", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)

      ap = AppProcess.create(
        group_name: "myapp",
        name: "init",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        umi_id: SecureRandom.uuid,
        umi_ref: "myapp@1.0",
        private_subnet_id: ps.id,
        desired_count: 1
      )

      tag = InitScriptTag.create(
        project_id: project.id,
        name: "setup",
        version: 1,
        init_script: "#!/bin/bash\necho hello"
      )

      AppProcessInit.create(
        app_process_id: ap.id,
        init_script_tag_id: tag.id,
        ordinal: 0
      )

      new_vm = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
      expect(Prog::Vm::Nexus).to receive(:assemble_with_sshable).and_return(
        instance_double(Strand, subject: new_vm)
      )

      expect { nx.check }.to hop("wait")

      member = ap.app_process_members_dataset.first
      expect(member.app_member_inits.count).to eq(1)
      expect(member.app_member_inits.first.init_script_tag_id).to eq(tag.id)
    end

    it "adds new VMs to load balancer when present" do
      ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-sub-7", location_id: Location::HETZNER_FSN1_ID).subject
      create_machine_image(name: "myapp@1.0", project_id: project.id, location_id: Location::HETZNER_FSN1_ID)

      lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "test-lb", src_port: 443, dst_port: 3000).subject

      ap = AppProcess.create(
        group_name: "myapp",
        name: "lbweb",
        project_id: project.id,
        location_id: Location::HETZNER_FSN1_ID,
        vm_size: "standard-2",
        umi_id: SecureRandom.uuid,
        umi_ref: "myapp@1.0",
        private_subnet_id: ps.id,
        desired_count: 1
      )

      new_vm = create_vm(project_id: project.id, location_id: Location::HETZNER_FSN1_ID)
      expect(Prog::Vm::Nexus).to receive(:assemble_with_sshable).and_return(
        instance_double(Strand, subject: new_vm)
      )

      expect(lb).to receive(:add_vm).with(new_vm)
      allow(ap).to receive(:load_balancer).and_return(lb)

      # We need to stub AppProcess.where to return our ap instance with the stubbed load_balancer
      allow(AppProcess).to receive(:where).and_call_original
      allow(AppProcess).to receive(:where).with(Sequel.lit(
        "desired_count > 0 AND umi_ref IS NOT NULL AND private_subnet_id IS NOT NULL AND vm_size IS NOT NULL"
      )).and_return([ap])

      expect { nx.check }.to hop("wait")
    end
  end

  describe "#wait" do
    it "naps for 60 seconds" do
      expect { nx.wait }.to nap(60)
    end
  end
end
