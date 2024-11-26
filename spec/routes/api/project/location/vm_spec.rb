# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-1").subject
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/location/#{vm.display_location}/vm"],
        [:post, "/project/#{project.ubid}/location/#{vm.display_location}/vm/foo_name"],
        [:delete, "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"],
        [:delete, "/project/#{project.ubid}/location/#{vm.display_location}/vm/_#{vm.ubid}"],
        [:get, "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"],
        [:get, "/project/#{project.ubid}/location/#{vm.display_location}/vm/_#{vm.ubid}"]
      ].each do |method, path|
        send method, path

        expect(last_response).to have_api_error(401, "Please login to continue")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    describe "list" do
      it "success multiple" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")

        get "/project/#{project.ubid}/location/#{vm.display_location}/vm"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(2)
        expect(parsed_body["count"]).to eq(2)
      end

      it "success multiple location with pagination" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-3")
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-4", location: "leaseweb-wdc02")

        get "/project/#{project.ubid}/location/#{vm.display_location}/vm", {
          order_column: "name",
          start_after: "dummy-vm-1"
        }

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(2)
        expect(parsed_body["count"]).to eq(3)
      end

      it "ubid not exist" do
        get "/project/#{project.ubid}/location/#{vm.display_location}/vm/_foo_ubid"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "create" do
      it "success" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be false
      end

      it "success with private subnet" do
        ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-fsn1").ubid

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          private_subnet_id: ps_id,
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be true
      end

      it "success with storage size" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          storage_size: "40"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
      end

      it "boot image doesn't passed" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "invalid name" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/MyVM", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          enable_ip4: true
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: name", {"name" => "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."})
      end

      it "invalid boot image" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "invalid-boot-image",
          enable_ip4: true
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: boot_image", {"boot_image" => "\"invalid-boot-image\" is not a valid boot image name. Available boot image names are: [\"ubuntu-noble\", \"ubuntu-jammy\", \"debian-12\", \"almalinux-9\"]"})
      end

      it "invalid vm size" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-gpu-6",
          enable_ip4: true
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: size", {"size" => "\"standard-gpu-6\" is not a valid virtual machine size. Available sizes: [\"standard-2\", \"standard-4\", \"standard-8\", \"standard-16\", \"standard-30\", \"standard-60\"]"})
      end

      it "success without vm_size" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          boot_image: "ubuntu-jammy",
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "invalid ps id" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          private_subnet_id: "invalid-ubid",
          enable_ip4: true
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id", {"private_subnet_id" => "Private subnet with the given id \"invalid-ubid\" is not found in the location \"eu-central-h1\""})
      end

      it "invalid ps id in other location" do
        ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "leaseweb-wdc02").ubid
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          private_subnet_id: ps_id,
          enable_ip4: true
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id", {"private_subnet_id" => "Private subnet with the given id \"#{ps_id}\" is not found in the location \"eu-central-h1\""})
      end
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(vm.name)
      end

      it "success ubid" do
        get "/project/#{project.ubid}/location/#{vm.display_location}/vm/_#{vm.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(vm.name)
      end

      it "not found" do
        get "/project/#{project.ubid}/location/#{vm.display_location}/vm/not-exists-vm"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/project/#{project.ubid}/location/#{vm.display_location}/vm/_#{vm.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/project/#{project.ubid}/location/#{vm.display_location}/vm/foo_name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end

      it "not exist ubid" do
        delete "/project/#{project.ubid}/location/#{vm.display_location}/vm/_foo_ubid"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end

      it "not exist ubid in location" do
        delete "/project/#{project.ubid}/location/foo_location/vm/_#{vm.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end
    end
  end
end
