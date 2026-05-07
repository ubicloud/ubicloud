# frozen_string_literal: true

require "google/cloud/compute/v1"

RSpec.describe Prog::Vm::Gcp::Nexus do
  subject(:nx) { described_class.new(st) }

  let(:st) { vm.strand }
  let(:nic) { vm.nics.first }

  let(:project) { Project.create(name: "test-prj") }

  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp", project_id: project.id,
      display_name: "gcp-us-central1", ui_name: "GCP US Central 1", visible: true)
  }

  let(:location_credential) {
    LocationCredentialGcp.create_with_id(location,
      project_id: "test-gcp-project",
      service_account_email: "test@test-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
  }

  let(:gcp_vpc) {
    vpc = GcpVpc.create(
      project_id: project.id,
      location_id: location.id,
      name: "ubicloud-#{project.ubid}-#{location.ubid}",
      network_self_link: "https://www.googleapis.com/compute/v1/projects/test-gcp-project/global/networks/12345",
    )
    Strand.create_with_id(vpc, prog: "Vnet::Gcp::VpcNexus", label: "wait")
    vpc
  }

  let(:vm) {
    location_credential
    gcp_vpc
    v = Prog::Vm::Nexus.assemble_with_sshable(project.id,
      location_id: location.id, unix_user: "test-user", boot_image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64",
      name: "testvm", size: "c4a-standard-8", arch: "arm64").subject
    DB[:private_subnet_gcp_vpc].insert(private_subnet_id: v.nics.first.private_subnet.id, gcp_vpc_id: gcp_vpc.id)
    v
  }

  let(:compute_client) { instance_double(Google::Cloud::Compute::V1::Instances::Rest::Client) }
  let(:nfp_client) { instance_double(Google::Cloud::Compute::V1::NetworkFirewallPolicies::Rest::Client) }
  let(:zone_ops_client) { instance_double(Google::Cloud::Compute::V1::ZoneOperations::Rest::Client) }

  def ensure_nic_gcp_resource(nic, **overrides)
    return if NicGcpResource[nic.id]
    ps = nic.private_subnet
    NicGcpResource.create_with_id(
      nic.id,
      vpc_name: ps.gcp_vpc.name,
      subnet_name: "ubicloud-#{ps.ubid}",
      **overrides,
    )
  end

  def ensure_vm_gcp_resource(vm, suffix)
    return if VmGcpResource[vm.id]
    VmGcpResource.create_with_id(vm,
      location_az_id: LocationAz[location_id: vm.location_id, az: suffix].id)
  end

  before do
    allow(nx.send(:credential)).to receive_messages(
      compute_client:,
      network_firewall_policies_client: nfp_client,
      zone_operations_client: zone_ops_client,
    )
    %w[a b c].each do |suffix|
      LocationAz.create(location_id: location.id, az: suffix)
    end
  end

  describe ".assemble" do
    it "creates storage volumes for gcp location" do
      expect(vm.vm_storage_volumes.count).to eq(1)
      expect(vm.vm_storage_volumes.first.boot).to be true
    end

    it "creates strand with Vm::Gcp::Nexus prog" do
      expect(vm.strand.prog).to eq("Vm::Gcp::Nexus")
    end

    it "creates no extra volumes for zero-size non-boot volumes" do
      location_credential
      gcp_vpc
      v = Prog::Vm::Nexus.assemble_with_sshable(project.id,
        location_id: location.id, unix_user: "test-user",
        boot_image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64",
        name: "testvm-zero", size: "c4a-standard-8", arch: "arm64",
        storage_volumes: [{size_gib: 375}, {size_gib: 0}]).subject
      expect(v.vm_storage_volumes.count).to eq(1)
      expect(v.vm_storage_volumes.first.boot).to be true
    end

    it "rejects attaching a VM to a grandfathered GCP subnet with more than 9 firewalls" do
      location_credential
      gcp_vpc
      subnet = Prog::Vnet::SubnetNexus.assemble(project.id, name: "grandfathered",
        location_id: location.id).subject
      9.times do |i|
        Firewall.create(name: "over-cap-fw-#{i}", description: "d",
          location_id: location.id, project_id: project.id)
          .associate_with_private_subnet(subnet, apply_firewalls: false)
      end
      expect(subnet.reload.firewalls.count).to be > 9
      expect {
        Prog::Vm::Nexus.assemble_with_sshable(project.id,
          location_id: location.id, unix_user: "test-user",
          boot_image: "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64",
          name: "testvm-overcap", size: "c4a-standard-8", arch: "arm64",
          private_subnet_id: subnet.id).subject
      }.to raise_error(Validation::ValidationFailed) { |e|
        expect(e.details[:firewall]).to match(/more than 9 firewalls/)
      }
    end

    # Lock-ordering and race behavior is covered by the real two-connection
    # concurrency specs in spec/model/firewall_concurrency_spec.rb. No smoke-
    # test stand-in here. It would only have been testable by mocking lock!,
    # and the prog re-fetches the subnet so the test's instance wouldn't be
    # the one we'd stub anyway.
  end

  describe "#before_destroy" do
    it "finalizes active billing records" do
      br = BillingRecord.create(
        project_id: project.id,
        resource_id: vm.id,
        resource_name: vm.name,
        billing_rate_id: BillingRate.from_resource_properties("VmVCpu", vm.family, vm.location.name)["id"],
        amount: vm.vcpus,
      )

      expect { nx.before_destroy }
        .to change { br.reload.span.unbounded_end? }.from(true).to(false)
    end

    it "completes without billing records" do
      expect(vm.active_billing_records).to be_empty
      expect { nx.before_destroy }.not_to change { vm.reload.active_billing_records.count }
    end
  end

  describe "#start" do
    before do
      nic.private_subnet.strand.update(label: "wait")
    end

    it "naps if private subnet is not in wait state" do
      nic.strand.update(label: "wait")
      nic.private_subnet.strand.update(label: "create_subnet")
      expect { nx.start }.to nap(5)
    end

    it "naps if vm nics are not in wait state" do
      nic.strand.update(label: "start")
      expect { nx.start }.to nap(1)
    end

    it "naps for the stashed retry_zone_delay and clears it" do
      refresh_frame(nx, new_values: {"retry_zone_delay" => 5 * 60})
      expect { nx.start }.to nap(5 * 60)
      expect(st.reload.stack.first["retry_zone_delay"]).to be_nil
    end

    it "creates a GCE instance without tags and hops to wait_create_op" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "a"})

      expect(Config).to receive(:provider_resource_tag_value).and_return("555666777")
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-12345")
      expect(compute_client).to receive(:insert) do |args|
        expect(args[:project]).to eq("test-gcp-project")
        expect(args[:zone]).to eq("us-central1-a")
        expect(args[:instance_resource]).to be_a(Google::Cloud::Compute::V1::Instance)
        expect(args[:instance_resource].name).to eq("testvm")
        expect(args[:instance_resource].machine_type).to include("c4a-standard-8-lssd")

        expect(args[:instance_resource].tags).to be_nil
        expect(args[:instance_resource].labels.to_h).to eq("ubicloud" => "555666777")

        ni = args[:instance_resource].network_interfaces.first
        expect(ni.network).to eq("projects/test-gcp-project/global/networks/ubicloud-#{project.ubid}-#{location.ubid}")
        expect(ni.subnetwork).to include("subnetworks/ubicloud-")
        expect(ni.network_i_p).to eq(vm.nic.private_ipv4.network.to_s)
        expect(ni.stack_type).to eq("IPV4_IPV6")
        expect(ni.ipv6_access_configs.first.name).to eq("External IPv6")
        expect(ni.ipv6_access_configs.first.type).to eq("DIRECT_IPV6")
        op
      end

      expect { nx.start }.to hop("wait_create_op")
      expect(st.reload.stack.first.dig("create_vm", "name")).to eq("op-12345")
    end

    it "selects a zone suffix and persists it in VM strand frame" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-zone")
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to hop("wait_create_op")
      expect(st.reload.stack.first["gcp_zone_suffix"]).to match(/\A[abc]\z/)
    end

    it "excludes zones from unsupported_azs on initial zone selection" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      refresh_frame(nx, new_values: {"unsupported_azs" => ["a", "b"]})

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-zone")
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to hop("wait_create_op")
      expect(st.reload.stack.first["gcp_zone_suffix"]).to eq("c")
    end

    it "preserves existing gcp_zone_suffix on re-entry (retry case)" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "c"})

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-zone")
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to hop("wait_create_op")
      expect(st.reload.stack.first["gcp_zone_suffix"]).to eq("c")
    end

    it "uses reserved static IP from NicGcpResource in AccessConfig" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic, address_name: "ubicloud-#{nic.name}", static_ip: "35.192.0.99")

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-static")
      expect(compute_client).to receive(:insert) do |args|
        ac = args[:instance_resource].network_interfaces.first.access_configs.first
        expect(ac.nat_i_p).to eq("35.192.0.99")
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "uses network config from NicGcpResource" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-net")
      expect(compute_client).to receive(:insert) do |args|
        ni = args[:instance_resource].network_interfaces.first
        ps = nic.private_subnet
        expect(ni.network).to include(ps.gcp_vpc.name)
        expect(ni.subnetwork).to include("ubicloud-#{ps.ubid}")
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    {
      "ResourceExhaustedError" => Google::Cloud::ResourceExhaustedError.new("zone capacity"),
      "UnavailableError" => Google::Cloud::UnavailableError.new("service unavailable"),
      "InvalidArgumentError for missing machine type" => Google::Cloud::InvalidArgumentError.new("Machine type with name 'c4a-standard-8-lssd' does not exist in zone 'us-central1-b'."),
    }.each do |label, error|
      it "retries in a different zone on #{label}" do
        nic.strand.update(label: "wait")
        ensure_nic_gcp_resource(nic)
        expect(compute_client).to receive(:insert).and_raise(error)
        expect(Clog).to receive(:emit).with("GCE zone retry", anything).and_call_original

        expect { nx.start }.to nap(5)
        stack = st.reload.stack.first
        expect(stack["exclude_zones"]).to be_a(Array)
        expect(stack["exclude_zones"].length).to eq(1)
        expect(stack["gcp_zone_suffix"]).not_to eq(stack["exclude_zones"].first)
      end
    end

    it "re-raises InvalidArgumentError when not about missing machine type" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      expect(compute_client).to receive(:insert).and_raise(
        Google::Cloud::InvalidArgumentError.new("Invalid disk size"),
      )

      expect { nx.start }.to raise_error(Google::Cloud::InvalidArgumentError, /Invalid disk size/)
    end

    it "resets exclusions and naps for 5 minutes when all zones are exhausted" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "c", "exclude_zones" => ["a", "b"]})
      ensure_vm_gcp_resource(vm, "c")

      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))
      expect(Clog).to receive(:emit).with("GCE zone retry exhausted, resetting exclusions", anything).and_call_original

      expect { nx.start }.to nap(5 * 60)
      stack = st.reload.stack.first
      expect(stack["exclude_zones"]).to eq([])
    end

    it "excludes failed zones on successive retries" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "b", "exclude_zones" => ["a"]})
      ensure_vm_gcp_resource(vm, "b")

      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))
      expect(Clog).to receive(:emit).with("GCE zone retry", anything).and_call_original

      expect { nx.start }.to nap(5)
      stack = st.reload.stack.first
      expect(stack["exclude_zones"]).to eq(["a", "b"])
      expect(stack["gcp_zone_suffix"]).to eq("c")
    end

    it "attaches only the boot disk when no non-boot volumes exist" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-boot-only")
      expect(compute_client).to receive(:insert) do |args|
        disks = args[:instance_resource].disks
        expect(disks.length).to eq(1)
        expect(disks[0].boot).to be true
        expect(disks[0].initialize_params.source_image).to eq(vm.boot_image)
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "attaches a SCRATCH local NVMe SSD for each non-boot vm_storage_volume" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 375, disk_index: 1)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-lssd-1")
      expect(compute_client).to receive(:insert) do |args|
        disks = args[:instance_resource].disks
        expect(disks.length).to eq(2)
        expect(disks[0].boot).to be true
        expect(disks[1].boot).to be false
        expect(disks[1].type).to eq("SCRATCH")
        expect(disks[1].interface).to eq("NVME")
        expect(disks[1].auto_delete).to be true
        expect(disks[1].initialize_params.disk_size_gb).to eq(375)
        expect(disks[1].initialize_params.disk_type).to include("diskTypes/local-ssd")
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "attaches multiple non-boot LSSDs in disk_index order" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 375, disk_index: 2)
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 375, disk_index: 1)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-lssd-2")
      expect(compute_client).to receive(:insert) do |args|
        disks = args[:instance_resource].disks
        expect(disks.length).to eq(3)
        expect(disks[0].boot).to be true
        expect(disks[1..].map(&:boot)).to eq([false, false])
        expect(disks[1..].map(&:type)).to eq(%w[SCRATCH SCRATCH])
        expect(disks[1..].map(&:interface)).to eq(%w[NVME NVME])
        op
      end

      expect { nx.start }.to hop("wait_create_op")
    end

    it "hops to wait_instance_created when instance already exists" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      expect(compute_client).to receive(:insert).and_raise(Google::Cloud::AlreadyExistsError.new("exists"))
      expect { nx.start }.to hop("wait_instance_created")
    end

    it "shell-escapes SSH keys in the startup script via NetSsh.command" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      captured_startup = nil
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-ssh")
      expect(compute_client).to receive(:insert) do |args|
        captured_startup = args[:instance_resource].metadata.items.find { |i| i.key == "startup-script" }.value
        op
      end

      expect { nx.start }.to hop("wait_create_op")

      expected_keys = vm.sshable.keys.map(&:public_key).join("\n")
      expect(captured_startup).to include(expected_keys.shellescape)
      expect(captured_startup).to include("> /home/#{vm.unix_user.shellescape}/.ssh/authorized_keys")
      expect(captured_startup).not_to include("base64 -d")
      expect(captured_startup).not_to include("$custom_user")
      expect(captured_startup).not_to include('#{')
    end

    it "creates a VmGcpResource row matching the chosen zone on first entry" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-vmgcp")
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to hop("wait_create_op")
      suffix = st.reload.stack.first["gcp_zone_suffix"]
      resource = VmGcpResource[vm.id]
      expect(resource).not_to be_nil
      expect(resource.location_az).to eq(LocationAz[location_id: location.id, az: suffix])
    end

    it "skips re-creating VmGcpResource if one already exists at first entry" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      pre_existing = VmGcpResource.create_with_id(vm,
        location_az_id: LocationAz[location_id: location.id, az: "a"].id)

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-preexist")
      expect(compute_client).to receive(:insert).and_return(op)

      expect { nx.start }.to hop("wait_create_op")
      expect(VmGcpResource.where(id: vm.id).count).to eq(1)
      expect(VmGcpResource[vm.id]).to eq(pre_existing)
    end

    it "updates the VmGcpResource row on zone-capacity retry" do
      nic.strand.update(label: "wait")
      ensure_nic_gcp_resource(nic)
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "a"})
      ensure_vm_gcp_resource(vm, "a")

      expect(compute_client).to receive(:insert)
        .and_raise(Google::Cloud::ResourceExhaustedError.new("zone capacity"))
      expect(Clog).to receive(:emit).with("GCE zone retry", anything).and_call_original

      expect { nx.start }.to nap(5)
      new_suffix = st.reload.stack.first["gcp_zone_suffix"]
      expect(new_suffix).not_to eq("a")
      expect(VmGcpResource[vm.id].location_az.az).to eq(new_suffix)
    end
  end

  describe "#wait_create_op" do
    it "naps when operation is still running" do
      refresh_frame(nx, new_values: {"create_vm" => {"name" => "op-123", "scope" => "zone", "scope_value" => "us-central1-a"}})

      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(zone_ops_client).to receive(:get).and_return(op)

      expect { nx.wait_create_op }.to nap(5)
    end

    it "hops to wait_instance_created when operation completes successfully" do
      refresh_frame(nx, new_values: {"create_vm" => {"name" => "op-123", "scope" => "zone", "scope_value" => "us-central1-a"}})

      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(zone_ops_client).to receive(:get).and_return(op)

      expect { nx.wait_create_op }.to hop("wait_instance_created")
    end

    it "raises if the GCE operation fails" do
      refresh_frame(nx, new_values: {"create_vm" => {"name" => "op-123", "scope" => "zone", "scope_value" => "us-central1-a"}})

      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "GENERIC_ERROR", message: "operation failed")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(zone_ops_client).to receive(:get).and_return(op)

      expect { nx.wait_create_op }.to raise_error(RuntimeError, /GCE instance creation failed.*operation failed/)
    end

    %w[ZONE_RESOURCE_POOL_EXHAUSTED ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS QUOTA_EXCEEDED].each do |code|
      it "retries in a different zone on #{code} operation error" do
        refresh_frame(nx, new_values: {"create_vm" => {"name" => "op-123", "scope" => "zone", "scope_value" => "us-central1-a"}, "gcp_zone_suffix" => "a"})
        ensure_vm_gcp_resource(vm, "a")

        error_entry = Google::Cloud::Compute::V1::Errors.new(code:, message: code)
        op = Google::Cloud::Compute::V1::Operation.new(
          status: :DONE,
          error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
        )
        expect(zone_ops_client).to receive(:get).and_return(op)
        expect(Clog).to receive(:emit).with("GCE zone retry", anything).and_call_original

        expect { nx.wait_create_op }.to hop("start")
        stack = st.reload.stack.first
        expect(stack["exclude_zones"]).to include("a")
        expect(stack["gcp_zone_suffix"]).not_to eq("a")
        expect(stack["create_vm_name"]).to be_nil
        expect(stack["retry_zone_delay"]).to eq(5)
      end
    end

    it "stashes a 5-minute backoff when all zones are exhausted on LRO error" do
      refresh_frame(nx, new_values: {"create_vm" => {"name" => "op-123", "scope" => "zone", "scope_value" => "us-central1-c"}, "gcp_zone_suffix" => "c", "exclude_zones" => ["a", "b"]})
      ensure_vm_gcp_resource(vm, "c")

      error_entry = Google::Cloud::Compute::V1::Errors.new(code: "ZONE_RESOURCE_POOL_EXHAUSTED", message: "exhausted")
      op = Google::Cloud::Compute::V1::Operation.new(
        status: :DONE,
        error: Google::Cloud::Compute::V1::Error.new(errors: [error_entry]),
      )
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect(Clog).to receive(:emit).with("GCE zone retry exhausted, resetting exclusions", anything).and_call_original

      expect { nx.wait_create_op }.to hop("start")
      stack = st.reload.stack.first
      expect(stack["exclude_zones"]).to eq([])
      expect(stack["retry_zone_delay"]).to eq(5 * 60)
    end
  end

  describe "#wait_instance_created" do
    before do
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "a"})
    end

    it "updates the vm and hops to wait_sshable when instance is RUNNING" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: [
          Google::Cloud::Compute::V1::NetworkInterface.new(
            access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(nat_i_p: "35.192.0.1"),
            ],
            ipv6_access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(external_ipv6: "2600:1900:4000:1::1"),
            ],
          ),
        ],
      )

      expect(compute_client).to receive(:get).with(
        project: "test-gcp-project",
        zone: "us-central1-a",
        instance: "testvm",
      ).and_return(instance)
      expect(Clog).to receive(:emit).with("GCP instance created", hash_including(gcp_instance_created: "testvm@us-central1-a")).and_call_original

      expect { nx.wait_instance_created }.to hop("wait_sshable")
        .and change { vm.reload.update_firewall_rules_set? }.from(false).to(true)
      expect(vm.cores).to eq(4)
      expect(vm.allocated_at).to be_within(2).of(Time.now)
      expect(vm.assigned_vm_address.ip.to_s).to eq("35.192.0.1/32")
      expect(vm.ephemeral_net6.to_s).to eq("2600:1900:4000:1::1/128")
    end

    it "updates the sshable host" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: [
          Google::Cloud::Compute::V1::NetworkInterface.new(
            access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(nat_i_p: "35.192.0.1"),
            ],
            ipv6_access_configs: [
              Google::Cloud::Compute::V1::AccessConfig.new(external_ipv6: "2600:1900:4000:1::1"),
            ],
          ),
        ],
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to hop("wait_sshable")
        .and change { vm.sshable.reload.host }.to("35.192.0.1")
    end

    it "updates the vm when instance is RUNNING without network interfaces" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: [],
      )

      expect(compute_client).to receive(:get).and_return(instance)

      expect { nx.wait_instance_created }.to hop("wait_sshable")
      vm.reload
      expect(vm.cores).to eq(4)
      expect(vm.assigned_vm_address).to be_nil
      expect(vm.ephemeral_net6).to be_nil
    end

    it "updates the vm when instance is RUNNING with empty access_configs" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "RUNNING",
        network_interfaces: [
          Google::Cloud::Compute::V1::NetworkInterface.new,
        ],
      )

      expect(compute_client).to receive(:get).and_return(instance)

      expect { nx.wait_instance_created }.to hop("wait_sshable")
      vm.reload
      expect(vm.cores).to eq(4)
      expect(vm.assigned_vm_address).to be_nil
      expect(vm.ephemeral_net6).to be_nil
    end

    it "naps if the instance is in STAGING state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "STAGING",
        network_interfaces: [],
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to nap(5)
    end

    it "naps if the instance is in PROVISIONING state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "PROVISIONING",
        network_interfaces: [],
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect { nx.wait_instance_created }.to nap(5)
    end

    it "pages and naps if the instance enters TERMINATED state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "TERMINATED",
        network_interfaces: [],
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect(Prog::PageNexus).to receive(:assemble).with(
        /entered terminal state TERMINATED during provisioning/,
        ["GceProvisionTerminal", vm.ubid, "TERMINATED"],
        vm.ubid,
      )
      expect(nx).to receive(:unregister_deadline).with("wait")
      expect { nx.wait_instance_created }.to nap(6 * 60 * 60)
    end

    it "pages and naps if the instance enters SUSPENDED state" do
      instance = Google::Cloud::Compute::V1::Instance.new(
        status: "SUSPENDED",
        network_interfaces: [],
      )

      expect(compute_client).to receive(:get).and_return(instance)
      expect(Prog::PageNexus).to receive(:assemble).with(
        /entered terminal state SUSPENDED during provisioning/,
        ["GceProvisionTerminal", vm.ubid, "SUSPENDED"],
        vm.ubid,
      )
      expect(nx).to receive(:unregister_deadline).with("wait")
      expect { nx.wait_instance_created }.to nap(6 * 60 * 60)
    end
  end

  describe "#wait_sshable" do
    it "pushes update_firewall_rules when semaphore is set" do
      nx.incr_update_firewall_rules
      expect(nx).to receive(:push).with(Prog::Vnet::Gcp::UpdateFirewallRules, {}, :update_firewall_rules).and_call_original
      expect { nx.wait_sshable }.to raise_error(Prog::Base::Hop)
    end

    it "decrements semaphore when firewall rules are added" do
      nx.incr_update_firewall_rules
      st.update(retval: Sequel.pg_jsonb({"msg" => "firewall rule is added"}))
      expect { nx.wait_sshable }.to hop("create_billing_record")
        .and change { vm.reload.update_firewall_rules_set? }.from(true).to(false)
    end

    it "naps if not sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "hops to create_billing_record if sshable" do
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "10.0.0.1/32")
      expect(Socket).to receive(:tcp).with("10.0.0.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end

    it "hops to create_billing_record if ipv4 is not available" do
      expect(vm.ip4).to be_nil
      expect { nx.wait_sshable }.to hop("create_billing_record")
    end
  end

  describe "#create_billing_record" do
    before do
      nx.vm.update(allocated_at: Time.now - 100)
      expect(Clog).to receive(:emit).with("vm provisioned", instance_of(Array)).and_call_original
    end

    it "does not create billing records when the project is not billable" do
      vm.project.update(billable: false)
      expect { nx.create_billing_record }.to hop("wait")
      expect(BillingRecord.all).to be_empty
    end

    it "creates billing records for vm" do
      expect { nx.create_billing_record }.to hop("wait")
        .and change(BillingRecord, :count).from(0).to(1)
        .and change { vm.reload.display_state }.from("creating").to("running")
      expect(vm.active_billing_records.first.billing_rate["resource_type"]).to eq("VmVCpu")
      expect(vm.provisioned_at).to be_within(2).of(Time.now)
    end
  end

  describe "#wait" do
    it "naps when nothing to do" do
      expect { nx.wait }.to nap(6 * 60 * 60)
    end

    it "hops to update_firewall_rules when needed" do
      nx.incr_update_firewall_rules
      expect { nx.wait }.to hop("update_firewall_rules")
    end
  end

  describe "#update_firewall_rules" do
    it "pushes firewall rules prog" do
      nx.incr_update_firewall_rules
      expect(nx).to receive(:push).with(Prog::Vnet::Gcp::UpdateFirewallRules, {}, :update_firewall_rules)
      nx.update_firewall_rules
      expect(Semaphore.where(strand_id: st.id, name: "update_firewall_rules").all).to be_empty
    end

    it "hops to wait if firewall rules are applied" do
      expect(nx).to receive(:retval).and_return({"msg" => "firewall rule is added"})
      expect { nx.update_firewall_rules }.to hop("wait")
    end
  end

  describe "#prevent_destroy" do
    it "registers a deadline and naps while preventing" do
      expect { nx.prevent_destroy }.to nap(30)
      expect(nx.strand.stack.first["deadline_target"]).to eq("destroy")
      expect(Time.new(nx.strand.stack.first["deadline_at"])).to be_within(5).of(Time.now + 24 * 60 * 60)
    end
  end

  describe "#destroy" do
    before do
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "a"})
    end

    it "prevents destroy if the semaphore set" do
      nx.incr_prevent_destroy
      expect(Clog).to receive(:emit).with("Destroy prevented by the semaphore").and_call_original
      expect { nx.destroy }.to hop("prevent_destroy")
    end

    it "deletes the GCE instance and hops to wait_destroy_op" do
      op = instance_double(Gapic::GenericLRO::Operation, name: "op-del-123")
      expect(compute_client).to receive(:delete).with(
        project: "test-gcp-project",
        zone: "us-central1-a",
        instance: "testvm",
      ).and_return(op)

      expect { nx.destroy }.to hop("wait_destroy_op")
      expect(st.reload.stack.first.dig("delete_vm", "name")).to eq("op-del-123")
    end

    it "handles already-deleted instances by hopping to finalize_destroy" do
      expect(compute_client).to receive(:delete).and_raise(Google::Cloud::NotFoundError.new("not found"))
      expect { nx.destroy }.to hop("finalize_destroy")
    end

    it "uses zone from VM strand frame when NIC is already destroyed" do
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "c"})
      nx.vm.nics.each do |n|
        n.strand.destroy
        n.destroy
      end

      op = instance_double(Gapic::GenericLRO::Operation, name: "op-del-zone")
      expect(compute_client).to receive(:delete).with(
        project: "test-gcp-project",
        zone: "us-central1-c",
        instance: "testvm",
      ).and_return(op)

      expect { nx.destroy }.to hop("wait_destroy_op")
    end
  end

  describe "#wait_destroy_op" do
    before do
      refresh_frame(nx, new_values: {"delete_vm" => {"name" => "op-del-123", "scope" => "zone", "scope_value" => "us-central1-a"}})
    end

    it "naps when operation is still running" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :RUNNING)
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_destroy_op }.to nap(5)
    end

    it "hops to finalize_destroy when operation completes" do
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE)
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_destroy_op }.to hop("finalize_destroy")
    end

    it "raises when operation completes with an error" do
      error = Google::Cloud::Compute::V1::Error.new(errors: [Google::Cloud::Compute::V1::Errors.new(code: "RESOURCE_NOT_FOUND", message: "instance not found")])
      op = Google::Cloud::Compute::V1::Operation.new(status: :DONE, error:)
      expect(zone_ops_client).to receive(:get).and_return(op)
      expect { nx.wait_destroy_op }.to raise_error(RuntimeError, /GCE instance deletion failed/)
    end
  end

  describe "#finalize_destroy" do
    it "destroys the vm and pops" do
      expect { nx.finalize_destroy }.to exit({"msg" => "vm destroyed"})
    end

    it "detaches NIC and increments destroy when NIC exists" do
      expect(nic.vm_id).to eq(vm.id)

      expect { nx.finalize_destroy }.to exit({"msg" => "vm destroyed"})
      expect(nic.reload.vm_id).to be_nil
      expect(Semaphore.where(strand_id: nic.strand.id, name: "destroy").count).to eq(1)
    end

    it "skips NIC detach when NIC is nil" do
      vm.nics.each { |n|
        n.strand.destroy
        n.destroy
      }

      expect { nx.finalize_destroy }.to exit({"msg" => "vm destroyed"})
    end
  end

  describe "helper methods" do
    it "delegates gce_machine_type to Option.gcp_instance_type_name" do
      nx.vm.update(family: "c4a-standard", vcpus: 8)
      expect(nx.send(:gce_machine_type)).to eq("c4a-standard-8-lssd")
    end

    it "reads GCP zone suffix from VM strand frame" do
      refresh_frame(nx, new_values: {"gcp_zone_suffix" => "c"})
      expect(nx.send(:gcp_zone)).to eq("us-central1-c")
    end

    it "samples from available AZ suffixes when not set in strand" do
      new_frame = nx.strand.stack.first.dup
      refresh_frame(nx, new_frame:)
      zone = nx.send(:gcp_zone)
      expect(zone).to match(/\Aus-central1-[abc]\z/)
    end

    it "returns the GCP region from location name" do
      expect(nx.send(:gcp_region)).to eq("us-central1")
    end

    describe "#gce_source_image" do
      it "returns projects/ paths as-is" do
        nx.vm.update(boot_image: "projects/my-project/global/images/my-image")
        expect(nx.send(:gce_source_image)).to eq("projects/my-project/global/images/my-image")
      end

      it "maps ubuntu-noble to the correct GCE family for x64" do
        nx.vm.update(boot_image: "ubuntu-noble", arch: "x64")
        expect(nx.send(:gce_source_image)).to eq("projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64")
      end

      it "maps ubuntu-noble to the correct GCE family for arm64" do
        nx.vm.update(boot_image: "ubuntu-noble", arch: "arm64")
        expect(nx.send(:gce_source_image)).to eq("projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-arm64")
      end

      it "maps ubuntu-jammy to the correct GCE family for x64" do
        nx.vm.update(boot_image: "ubuntu-jammy", arch: "x64")
        expect(nx.send(:gce_source_image)).to eq("projects/ubuntu-os-cloud/global/images/family/ubuntu-2204-lts-amd64")
      end

      it "raises for unknown boot images" do
        nx.vm.update(boot_image: "unknown-image")
        expect { nx.send(:gce_source_image) }.to raise_error(RuntimeError, /Unknown boot image/)
      end
    end

    describe "#location_az_for" do
      it "returns the location_az for a known suffix" do
        expect(nx.send(:location_az_for, "a")).to eq(LocationAz[location_id: location.id, az: "a"])
      end

      it "raises when no location_az row exists for the suffix" do
        expect { nx.send(:location_az_for, "z") }.to raise_error(RuntimeError, %r{no location_az row for gcp-us-central1/z})
      end
    end
  end
end
