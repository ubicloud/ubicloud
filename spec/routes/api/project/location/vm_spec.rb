# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-1").subject
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/location/#{vm.display_location}/vm"],
        [:post, "/project/#{project.ubid}/location/#{vm.display_location}/vm/foo_name"],
        [:delete, "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"],
        [:delete, "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.ubid}"],
        [:get, "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"],
        [:get, "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.ubid}"]
      ].each do |method, path|
        send method, path

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    describe "list" do
      it "success multiple" do
        Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-2")

        get "/project/#{project.ubid}/location/#{vm.display_location}/vm"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(2)
        expect(parsed_body["count"]).to eq(2)
      end

      it "success multiple location with pagination" do
        Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-2")
        Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-3")
        Prog::Vm::Nexus.assemble("dummy-public key", project.id, name: "dummy-vm-4", location_id: "e0865080-9a3d-8020-a812-f5817c7afe7f")

        get "/project/#{project.ubid}/location/#{vm.display_location}/vm", {
          order_column: "name",
          start_after: "dummy-vm-1"
        }

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(2)
        expect(parsed_body["count"]).to eq(3)
      end

      it "location not exist" do
        get "/project/#{project.ubid}/location/not-exist-location/vm"

        expect(last_response).to have_api_error(404, "Validation failed for following path components: location")
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
        ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: Location[display_name: TEST_LOCATION].id).ubid

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

      it "success with private location tied to current project" do
        Location.where(display_name: TEST_LOCATION).update(visible: false, project_id: project.id)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          size: "standard-2"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be false
      end

      it "failure with private location tied to other project" do
        Location.where(display_name: TEST_LOCATION).update(visible: false, project_id: Project.create(name: "bad").id)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          size: "standard-2"
        }.to_json

        expect(last_response).to have_api_error(404, "Validation failed for following path components: location", {"location" => "Given location is not a valid location. Available locations: eu-north-h1, us-east-a2"})
      end

      it "failure with invisible location" do
        Location.where(display_name: TEST_LOCATION).update(visible: false)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          size: "standard-2"
        }.to_json

        expect(last_response).to have_api_error(404, "Validation failed for following path components: location", {"location" => "Given location is not a valid location. Available locations: eu-north-h1, us-east-a2"})
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

        expect(last_response).to have_api_error(400, "Validation failed for following fields: size", {"size" => "\"standard-gpu-6\" is not a valid virtual machine size. Available sizes: [\"standard-2\", \"standard-4\", \"standard-8\", \"standard-16\", \"standard-30\", \"standard-60\", \"burstable-1\", \"burstable-2\"]"})
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
        ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location_id: "e0865080-9a3d-8020-a812-f5817c7afe7f").ubid
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

      it "invalid gpu format" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          enable_ip4: true,
          gpu: "invalid-gpu-format"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: gpu", {"gpu" => "gpu field must be in the format 'count:device_name'."})
      end

      it "invalid gpu count" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          enable_ip4: true,
          gpu: "3:20b5"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: gpu", {"gpu" => "gpu count must be one of the following: 0, 1, 2, 4, 8"})
      end

      it "feature flag not set for gpu vm" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          enable_ip4: true,
          gpu: "1:20b5"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: gpu", {"gpu" => "gpu not available for this project"})
      end

      it "unsupported gpu type" do
        project.set_ff_gpu_vm(true)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          enable_ip4: true,
          gpu: "1:unsupported"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: gpu", {"gpu" => "gpu type unsupported"})
      end

      it "unsupported gpu family" do
        project.set_ff_gpu_vm(true)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "burstable-2",
          enable_ip4: true,
          gpu: "1:20b5"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: gpu", {"gpu" => "gpu not available for burstable vms"})
      end

      it "unspecified gpu type" do
        project.set_ff_gpu_vm(true)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          enable_ip4: true,
          gpu: "1:"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: gpu", {"gpu" => "gpu type must be specified when gpu count is greater than 0."})
      end
    end

    it "succeeds with gpu count of zero" do
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
        public_key: "ssh key",
        unix_user: "ubi",
        size: "standard-2",
        enable_ip4: true,
        gpu: "0:"
      }.to_json

      expect(last_response.status).to eq(200)
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(vm.name)
      end

      it "success ubid" do
        get "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.ubid}"

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
        delete "/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/project/#{project.ubid}/location/#{vm.display_location}/vm/foo-name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end

      it "returns appropriate error message for accessing invalid location" do
        delete "/project/#{project.ubid}/location/us-east-a3/vm/#{vm.ubid}"

        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)).to eq("error" => {"code" => 404, "details" => {"location" => "Given location is not a valid location. Available locations: eu-central-h1, eu-north-h1, us-east-a2"}, "message" => "Validation failed for following path components: location", "type" => "InvalidLocation"})
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end

      it "returns appropriate error message for trying to create in internal location" do
        post "/project/#{project.ubid}/location/github-runners/vm/test-vm", {
          public_key: "ssh key"
        }.to_json

        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)).to eq("error" => {"code" => 404, "details" => {"location" => "Given location is not a valid location. Available locations: eu-central-h1, eu-north-h1, us-east-a2"}, "message" => "Validation failed for following path components: location", "type" => "InvalidLocation"})
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end
    end
  end
end
