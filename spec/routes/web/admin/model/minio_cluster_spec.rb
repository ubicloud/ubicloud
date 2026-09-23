# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "MinioCluster" do
  include AdminModelSpecHelper

  before do
    @instance = create_minio_cluster
    admin_account_setup_and_login
  end

  it "displays the MinioCluster instance page correctly" do
    click_link "MinioCluster"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioCluster"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - MinioCluster #{@instance.ubid}"
  end

  describe "Recreate Server VM" do
    let(:servers) {
      pool = MinioPool.create(cluster_id: @instance.id, server_count: 2, drive_count: 2, storage_size_gib: 200, vm_size: "standard-2", start_index: 0)
      address = Address.create(cidr: "1.2.3.0/24", routed_to_host_id: create_vm_host.id)
      Array.new(2) do |index|
        vm = Prog::Vm::Nexus.assemble_with_sshable(@instance.project_id, name: "minio-vm-#{index}", private_subnet_id: @instance.private_subnet_id).subject
        AssignedVmAddress.create(ip: "1.2.3.#{index + 4}", address_id: address.id, dst_vm_id: vm.id)
        server = MinioServer.create(minio_pool_id: pool.id, vm_id: vm.id, index:)
        Strand.create_with_id(server, prog: "Minio::MinioServerNexus", label: "wait")
        server
      end
    }
    let(:options) { servers.map { "test-cluster#{it.index}.minio.ubicloud.com (#{it.ubid})" } }
    let(:info_url) { "https://1.2.3.5:9000/minio/admin/v3/info" }

    def stub_info(state)
      stub_request(:get, info_url).to_return(status: 200, body: JSON.generate({servers: [
        {state: "online", endpoint: "test-cluster0.minio.ubicloud.com:9000", drives: [{state: "ok"}]},
        {state:, endpoint: "test-cluster1.minio.ubicloud.com:9000", drives: [{state: "ok"}]},
      ]}))
    end

    before do
      servers
      visit "/model/MinioCluster/#{@instance.ubid}"
      click_link "Recreate Server VM"
    end

    it "lists the servers of the cluster and schedules the recreation of the selected one" do
      stub_info("online")
      expect(page.all("select[name=minio_server] option").map(&:text)).to eq ["", *options]

      select options[1], from: "minio_server"
      select options[1], from: "minio_server_confirmation"
      click_button "Recreate Server VM"
      expect(page).to have_flash_notice("VM recreation scheduled for MinioServer")
      expect(page.title).to eq "Ubicloud Admin - MinioCluster #{@instance.ubid}"
      expect(Strand.where(prog: "Minio::RecreateVm").select_map(:stack)).to eq [[{"subject_id" => servers[1].id}]]
    end

    it "fails if the confirmation does not match" do
      dont_raise_admin_errors do
        select options[1], from: "minio_server"
        select options[0], from: "minio_server_confirmation"
        click_button "Recreate Server VM"
        expect(page).to have_content "InvalidRequest: Minio server confirmation does not match"
        expect(Strand.where(prog: "Minio::RecreateVm").count).to eq 0
      end
    end

    it "shows the error if the cluster is not healthy" do
      stub_info("offline")

      select options[1], from: "minio_server"
      select options[1], from: "minio_server_confirmation"
      click_button "Recreate Server VM"
      expect(page).to have_flash_error("Minio pool is not healthy")
      expect(page.title).to eq "Ubicloud Admin - MinioCluster #{@instance.ubid}"
      expect(Strand.where(prog: "Minio::RecreateVm").count).to eq 0
    end

    it "shows the error if the cluster is not reachable" do
      stub_request(:get, info_url).to_raise(Excon::Error::Socket.new(Errno::ECONNREFUSED.new))

      select options[1], from: "minio_server"
      select options[1], from: "minio_server_confirmation"
      click_button "Recreate Server VM"
      expect(page).to have_flash_error(/Connection refused/)
      expect(page.title).to eq "Ubicloud Admin - MinioCluster #{@instance.ubid}"
    end
  end
end
