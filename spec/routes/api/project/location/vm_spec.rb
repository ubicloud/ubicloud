# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "vm" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:vm) do
    vm = Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-1").subject
    vm.update(ephemeral_net6: "2a01:4f8:173:1ed3:aa7c::/79")
    vm.reload # without reload ephemeral_net6 is string and can't call .network
  end

  describe "unauthenticated" do
    it "not location list" do
      get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not create" do
      post "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/foo_name"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not delete" do
      delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not delete ubid" do
      delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/#{vm.ubid}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not get ubid" do
      get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/#{vm.ubid}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not create firewall rule" do
      post "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not delete firewall rule" do
      delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule/foo_ubid"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
    end

    describe "list" do
      it "empty" do
        get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"]).to eq([])
        expect(parsed_body["count"]).to eq(0)
      end

      it "success single" do
        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(1)
        expect(parsed_body["count"]).to eq(1)
      end

      it "success multiple" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")

        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm"

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(2)
        expect(parsed_body["count"]).to eq(2)
      end

      it "success multiple location with pagination" do
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-2")
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-3")
        Prog::Vm::Nexus.assemble("dummy-public-key", project.id, name: "dummy-vm-4", location: "hetzner-fsn1")

        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm", {
          order_column: "name",
          start_after: "dummy-vm-1"
        }

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["items"].length).to eq(2)
        expect(parsed_body["count"]).to eq(3)
      end

      it "ubid not exist" do
        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/foo_ubid"

        expect(last_response.status).to eq(404)
      end
    end

    describe "create" do
      it "success" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be false
      end

      it "success with ipv4" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be true
      end

      it "success with private subnet" do
        ps_id = Prog::Vnet::SubnetNexus.assemble(project.id, name: "dummy-ps-1", location: "hetzner-hel1").ubid

        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          private_subnet_id: ps_id,
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(200)
        parsed_body = JSON.parse(last_response.body)
        expect(parsed_body["name"]).to eq("test-vm")
        expect(parsed_body["name"]).to eq("test-vm")
        expect(Vm.first.ip4_enabled).to be true
      end

      it "boot image doesn't passed" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "invalid boot image" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "invalid-boot-image",
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["boot_image"]).to eq("\"invalid-boot-image\" is not a valid boot image name. Available boot image names are: [\"ubuntu-jammy\", \"almalinux-9.1\"]")
      end

      it "invalid ps id" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy",
          private_subnet_id: "invalid-ubid",
          enable_ip4: true
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["private_subnet_id"]).to eq("Private subnet with the given id \"invalid-ubid\" is not found")
      end

      it "invalid name" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/invalid_name", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["name"]).to eq("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
      end

      it "invalid payment method" do
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key")
        expect(Project).to receive(:from_ubid).and_return(project)

        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          unix_user: "ubi",
          size: "standard-2",
          boot_image: "ubuntu-jammy"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["billing_info"]).to eq("Project doesn't have valid billing information")
      end

      it "invalid body" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", "invalid_body"

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["body"]).to eq("Request body isn't a valid JSON object.")
      end

      it "missing required key" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          unix_user: "ubi"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["body"]).to eq("Request body must include required parameters: public_key")
      end

      it "non allowed key" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/test-vm", {
          public_key: "ssh key",
          foo_key: "foo_val"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["body"]).to eq("Only following parameters are allowed: public_key, size, unix_user, boot_image, enable_ip4, private_subnet_id")
      end

      it "firewall-rule" do
        post "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule", {
          cidr: "0.0.0.0/0",
          port_range: "100..101"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule vm ubid" do
        post "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/#{vm.ubid}/firewall-rule", {
          cidr: "0.0.0.0/0",
          port_range: "100..1012"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule no port range" do
        post "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule", {
          cidr: "0.0.0.0/1"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule single port" do
        post "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule", {
          cidr: "0.0.0.0/1",
          port_range: "11111"
        }.to_json

        expect(last_response.status).to eq(200)
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(vm.name)
      end

      it "success ubid" do
        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/#{vm.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(vm.name)
      end

      it "not found" do
        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/not-exists-vm"

        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "firewall" do
        get "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["description"]).to eq("Default firewall")
      end
    end

    describe "delete" do
      it "success" do
        delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/#{vm.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/foo_name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end

      it "not exist ubid" do
        delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/foo_ubid"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(vm.id).set?("destroy")).to be false
      end

      it "firewall-rule" do
        delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule/#{vm.firewalls.map(&:firewall_rules).flatten.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule ubid" do
        delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/id/#{vm.ubid}/firewall-rule/#{vm.firewalls.map(&:firewall_rules).flatten.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule not exist" do
        delete "/api/project/#{project.ubid}/location/#{vm.display_location}/vm/#{vm.name}/firewall-rule/foo_ubid"

        expect(last_response.status).to eq(204)
      end
    end
  end
end
