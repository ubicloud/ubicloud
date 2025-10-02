# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "load-balancer" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:lb) do
    ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "subnet-1", location_id: Location[display_name: TEST_LOCATION].id)
    dz = DnsZone.create(name: "test-dns-zone", project_id: project.id)
    cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
    lb = Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "lb-1", src_port: 80, dst_port: 8080).subject
    lb.add_cert(cert)
    lb
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/load-balancer"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/lb-1"],
        [:delete, "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}"],
        [:get, "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}/attach-vm", {vm_id: "vm-1"}],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}/detach-vm", {vm_id: "vm-1"}],
        [:get, "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.ubid}"]
      ].each do |method, path, body|
        send(method, path, body)

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
      lb_project = Project.create(name: "default")
      allow(Config).to receive(:load_balancer_service_project_id).and_return(lb_project.id)
    end

    describe "list" do
      it "empty" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "success single" do
        lb

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(1)
      end

      it "success multiple" do
        lb
        Prog::Vnet::LoadBalancerNexus.assemble(lb.private_subnet.id, name: "lb-2", src_port: 80, dst_port: 8080).subject

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end
    end

    describe "id" do
      it "success" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("lb-1")
      end

      it "not found" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/not-found"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "create" do
      it "success" do
        ps = Prog::Vnet::SubnetNexus.assemble(project.id, name: "subnet-1", location_id: Location[display_name: TEST_LOCATION].id).subject
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/lb1", {
          private_subnet_id: ps.ubid,
          stack: LoadBalancer::Stack::IPV4,
          src_port: "80", dst_port: "8080",
          health_check_endpoint: "/up", algorithm: "round_robin",
          health_check_protocol: "http",
          cert_enabled: false
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("lb1")
      end

      it "invalid private_subnet_id" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/lb1", {
          private_subnet_id: "invalid",
          stack: LoadBalancer::Stack::IPV6,
          src_port: "80", dst_port: "8080",
          health_check_endpoint: "/up", algorithm: "round_robin",
          health_check_protocol: "http",
          cert_enabled: false
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: private_subnet_id")
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}"

        expect(last_response.status).to eq(204)
      end
    end

    describe "get" do
      it "success" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("lb-1")
      end

      it "not found" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/invalid"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end
    end

    describe "update" do
      let(:vm) {
        nic = Nic.create(name: "nic-1", private_subnet_id: lb.private_subnet.id, mac: "00:00:00:00:00:01", private_ipv4: "1.1.1.1", private_ipv6: "2001:db8::1")
        vm = create_vm
        nic.update(vm_id: vm.id)
        vm.update(project_id: project.id)
        vm
      }

      it "success" do
        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}", {
          src_port: "80", dst_port: "8080",
          health_check_endpoint: "/up", algorithm: "round_robin", vms: [], cert_enabled: false
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("lb-1")
      end

      it "not found" do
        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/invalid", {
          src_port: "80", dst_port: "8080",
          health_check_endpoint: "/up", algorithm: "round_robin", vms: [], cert_enabled: false
        }.to_json

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "missing required parameters" do
        expect do
          patch "/project/#{project.ubid}/location/#{lb.private_subnet.display_location}/load-balancer/#{lb.name}", {}.to_json
        end.to raise_error(Committee::InvalidRequest, /missing required parameters: algorithm, dst_port, health_check_endpoint, src_port, vms/)
      end

      it "updates vms" do
        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}", {
          src_port: "80", dst_port: "8080", health_check_endpoint: "/up", algorithm: "round_robin", vms: [vm.ubid], cert_enabled: false
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["vms"].length).to eq(1)
      end

      it "detaches vms" do
        lb.add_vm(vm)

        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}", {
          src_port: "80", dst_port: "8080", health_check_endpoint: "/up", algorithm: "round_robin", vms: [],
          cert_enabled: false
        }.to_json

        expect(last_response.status).to eq(200)
        expect(lb.reload.vms.count).to eq(0)
        expect(JSON.parse(last_response.body)["vms"]).to eq([])
      end

      it "invalid vm" do
        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}", {
          src_port: "80", dst_port: "80", health_check_endpoint: "/up", algorithm: "round_robin", vms: ["invalid"], cert_enabled: false
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: vms")
      end

      it "vm already attached to a different load balancer" do
        lb2 = Prog::Vnet::LoadBalancerNexus.assemble(lb.private_subnet.id, name: "lb-2", src_port: 80, dst_port: 8080).subject
        dz = DnsZone.create(name: "test-dns-zone2", project_id: lb2.private_subnet.project_id)
        cert = Prog::Vnet::CertNexus.assemble("test-host-name", dz.id).subject
        lb2.add_cert(cert)
        lb2.add_vm(vm)

        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}", {
          src_port: "80", dst_port: "8080", health_check_endpoint: "/up", algorithm: "round_robin", vms: [vm.ubid], cert_enabled: false
        }.to_json

        expect(last_response).to have_api_error(400)
      end

      it "vm already attached to the same load balancer" do
        lb.add_vm(vm)

        patch "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}", {
          src_port: "80", dst_port: "8080", health_check_endpoint: "/up", algorithm: "round_robin", vms: [vm.ubid], cert_enabled: false
        }.to_json

        expect(last_response.status).to eq(200)
      end
    end

    describe "attach-vm" do
      let(:vm) {
        nic = Nic.create(name: "nic-1", private_subnet_id: lb.private_subnet.id, mac: "00:00:00:00:00:01", private_ipv4: "1.1.1.1", private_ipv6: "2001:db8::1")
        vm = create_vm
        nic.update(vm_id: vm.id)
        vm
      }

      it "success" do
        vm.update(project_id: project.id)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}/attach-vm", {vm_id: vm.ubid}.to_json

        expect(last_response.status).to eq(200)
      end

      it "not existing vm" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}/attach-vm", {vm_id: "invalid"}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
      end

      it "fails for vm in different location" do
        vm.update(location_id: Location::HETZNER_HEL1_ID)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}/attach-vm", {vm_id: vm.ubid}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
      end
    end

    describe "detach-vm" do
      let(:vm) {
        nic = Nic.create(name: "nic-1", private_subnet_id: lb.private_subnet.id, mac: "00:00:00:00:00:01", private_ipv4: "1.1.1.1", private_ipv6: "2001:db8::1")
        vm = create_vm
        nic.update(vm_id: vm.id)
        vm
      }

      it "success" do
        vm.update(project_id: project.id)
        lb.add_vm(vm)

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}/detach-vm", {vm_id: vm.ubid}.to_json

        expect(last_response.status).to eq(200)
      end

      it "not existing vm" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/load-balancer/#{lb.name}/detach-vm", {vm_id: "invalid"}.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: vm_id")
      end
    end
  end
end
