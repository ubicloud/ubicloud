# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "app" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }
  let(:project_wo_permissions) { user.create_project_with_default_policy("default", default_policy: nil) }

  let(:ps) do
    Prog::Vnet::SubnetNexus.assemble(project.id, name: "test-subnet", location_id: Location[display_name: TEST_LOCATION].id).subject
  end

  let(:ap) do
    AppProcess.create(
      group_name: "myapp",
      name: "web",
      project_id: project.id,
      location_id: Location[display_name: TEST_LOCATION].id,
      private_subnet_id: ps.id
    )
  end

  let(:vm) do
    nic = Nic.create(name: "nic-1", private_subnet_id: ps.id, mac: "00:00:00:00:00:01", private_ipv4: "1.1.1.0", private_ipv6: "2001:db8::1", state: "active")
    vm = create_vm(name: "test-vm-1", project_id: project.id, location_id: Location[display_name: TEST_LOCATION].id)
    nic.update(vm_id: vm.id)
    vm
  end

  around do |example|
    ENV["IGNORE_INVALID_API_PATHS"] = "1"
    example.run
    ENV.delete("IGNORE_INVALID_API_PATHS")
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      [
        [:get, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"],
        [:get, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"],
        [:delete, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/add"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/detach"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/remove"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set"],
        [:post, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/scale"],
        [:get, "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/releases"]
      ].each do |method, path, body|
        send(method, path, body)

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
    end

    describe "list" do
      it "returns empty list" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "returns single app process" do
        ap

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["items"].length).to eq(1)
        expect(parsed["items"][0]["name"]).to eq("myapp-web")
      end

      it "returns multiple app processes" do
        ap
        AppProcess.create(
          group_name: "myapp",
          name: "wkr",
          project_id: project.id,
          location_id: Location[display_name: TEST_LOCATION].id,
          private_subnet_id: ps.id
        )

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end
    end

    describe "create" do
      it "creates an app process with group name derived from name" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/myapp-web", {
          subnet_name: ps.name
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["name"]).to eq("myapp-web")
        expect(parsed["group_name"]).to eq("myapp")
        expect(parsed["process_name"]).to eq("web")
        expect(parsed["subnet"]).to eq(ps.name)
      end

      it "creates an app process with explicit group name" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/myapp-web", {
          group_name: "myapp",
          subnet_name: ps.name
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["group_name"]).to eq("myapp")
        expect(parsed["process_name"]).to eq("web")
      end

      it "creates an app process with vm_size" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/myapp-web", {
          subnet_name: ps.name,
          vm_size: "standard-2"
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["vm_size"]).to eq("standard-2")
      end

      it "fails with nonexistent subnet" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/myapp-web", {
          subnet_name: "nonexistent"
        }.to_json

        expect(last_response.status).to eq(400)
      end
    end

    describe "show" do
      it "returns detailed app process" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["name"]).to eq("myapp-web")
        expect(parsed["group_name"]).to eq("myapp")
        expect(parsed["process_name"]).to eq("web")
        expect(parsed["desired_count"]).to eq(0)
        expect(parsed["members"]).to be_an(Array)
        expect(parsed["aliens"]).to be_an(Array)
        expect(parsed["empty_slots"]).to eq(0)
        expect(parsed["init_tags"]).to be_an(Array)
        expect(parsed["deployment_managed"]).to eq(false)
      end

      it "returns app process by ubid" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("myapp-web")
      end

      it "returns not found for nonexistent app" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/nonexistent"

        expect(last_response.status).to eq(404)
      end

      it "includes members and their state" do
        AppProcessMember.create(
          app_process_id: ap.id,
          vm_id: vm.id,
          ordinal: 0,
          state: "active"
        )

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["members"].length).to eq(1)
        expect(parsed["members"][0]["vm_name"]).to eq("test-vm-1")
        expect(parsed["members"][0]["state"]).to eq("active")
      end

      it "includes init tags on process type" do
        tag = InitScriptTag.create(
          project_id: project.id,
          name: "secrets",
          version: 1,
          init_script: "#!/bin/bash\necho secret"
        )
        AppProcessInit.create(
          app_process_id: ap.id,
          init_script_tag_id: tag.id,
          ordinal: 0
        )

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["init_tags"].length).to eq(1)
        expect(parsed["init_tags"][0]["name"]).to eq("secrets")
        expect(parsed["init_tags"][0]["version"]).to eq(1)
        expect(parsed["init_tags"][0]["ref"]).to eq("secrets@1")
      end

      it "shows empty slots when desired > actual" do
        ap.update(desired_count: 3)

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["empty_slots"]).to eq(3)
      end

      it "shows LB name when LB exists on subnet" do
        Prog::Vnet::LoadBalancerNexus.assemble(ps.id, name: "my-lb", src_port: 443, dst_port: 3000)

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["lb_name"]).to eq("my-lb")
      end

      it "includes alien VMs on subnet but not in process" do
        # Create a VM on the subnet but NOT as a member
        nic = Nic.create(name: "alien-nic", private_subnet_id: ps.id, mac: "00:00:00:00:00:02", private_ipv4: "1.1.1.1", private_ipv6: "2001:db8::2", state: "active")
        alien_vm = create_vm(name: "alien-vm", project_id: project.id, location_id: Location[display_name: TEST_LOCATION].id)
        nic.update(vm_id: alien_vm.id)

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["aliens"].length).to eq(1)
        expect(parsed["aliens"][0]["vm_name"]).to eq("alien-vm")
      end
    end

    describe "add" do
      it "claims existing VM into process type" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/add", {
          vm_names: [vm.name]
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["members"].length).to eq(1)
        expect(parsed["members"][0]["vm_name"]).to eq(vm.name)
        expect(parsed["desired_count"]).to eq(1)
      end

      it "increments desired_count when adding a VM" do
        expect(ap.desired_count).to eq(0)

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/add", {
          vm_names: [vm.name]
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["desired_count"]).to eq(1)
        expect(ap.reload.desired_count).to eq(1)
      end

      it "fails when VM not found" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/add", {
          vm_names: ["nonexistent-vm"]
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "fails when VM already a member of another process" do
        AppProcessMember.create(
          app_process_id: ap.id,
          vm_id: vm.id,
          ordinal: 0,
          state: "active"
        )

        ap2 = AppProcess.create(
          group_name: "myapp",
          name: "wkr",
          project_id: project.id,
          location_id: Location[display_name: TEST_LOCATION].id,
          private_subnet_id: ps.id
        )

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap2.flat_name}/add", {
          vm_names: [vm.name]
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "fails to create new VM without UMI" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/add", {}.to_json

        expect(last_response.status).to eq(400)
      end

      it "copies init tags to new member" do
        tag = InitScriptTag.create(
          project_id: project.id,
          name: "secrets",
          version: 1,
          init_script: "#!/bin/bash\necho secret"
        )
        AppProcessInit.create(
          app_process_id: ap.id,
          init_script_tag_id: tag.id,
          ordinal: 0
        )

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/add", {
          vm_names: [vm.name]
        }.to_json

        expect(last_response.status).to eq(200)
        member = AppProcessMember.first(app_process_id: ap.id, vm_id: vm.id)
        expect(member.app_member_inits.length).to eq(1)
        expect(member.app_member_inits[0].init_script_tag_id).to eq(tag.id)
      end
    end

    describe "detach" do
      it "detaches VM from process, desired_count unchanged" do
        ap.update(desired_count: 1)
        AppProcessMember.create(
          app_process_id: ap.id,
          vm_id: vm.id,
          ordinal: 0,
          state: "active"
        )

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/detach", {
          vm_name: vm.name
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["members"].length).to eq(0)
        expect(parsed["desired_count"]).to eq(1)  # unchanged
      end

      it "fails when VM is not a member" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/detach", {
          vm_name: "nonexistent-vm"
        }.to_json

        expect(last_response.status).to eq(400)
      end
    end

    describe "remove" do
      it "removes VM and decrements desired_count" do
        ap.update(desired_count: 1)
        AppProcessMember.create(
          app_process_id: ap.id,
          vm_id: vm.id,
          ordinal: 0,
          state: "active"
        )

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/remove", {
          vm_name: vm.name
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["members"].length).to eq(0)
        expect(parsed["desired_count"]).to eq(0)  # decremented
      end

      it "fails when VM is not a member" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/remove", {
          vm_name: "nonexistent-vm"
        }.to_json

        expect(last_response.status).to eq(400)
      end
    end

    describe "set" do
      it "sets UMI reference" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          umi: "ubuntu-noble"
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["umi_ref"]).to eq("ubuntu-noble")
        expect(parsed["deployment_managed"]).to eq(true)
      end

      it "sets VM size" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          vm_size: "standard-4"
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["vm_size"]).to eq("standard-4")
      end

      it "sets init script with name@version reference" do
        InitScriptTag.create(
          project_id: project.id,
          name: "secrets",
          version: 1,
          init_script: "#!/bin/bash\necho secret"
        )

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          init: ["secrets@1"]
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["init_tags"].length).to eq(1)
        expect(parsed["init_tags"][0]["ref"]).to eq("secrets@1")
      end

      it "pushes init script with name=content" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          init: ["deploy=#!/bin/bash\necho deploy"]
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["init_tags"].length).to eq(1)
        expect(parsed["init_tags"][0]["name"]).to eq("deploy")
        expect(parsed["init_tags"][0]["version"]).to eq(1)
      end

      it "creates a release when UMI is set" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          umi: "ubuntu-noble"
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["release_number"]).to eq(1)
      end

      it "creates a release when init changes" do
        InitScriptTag.create(
          project_id: project.id,
          name: "secrets",
          version: 1,
          init_script: "#!/bin/bash\necho secret"
        )

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          init: ["secrets@1"]
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["release_number"]).to eq(1)
      end

      it "fails without any option" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {}.to_json

        expect(last_response.status).to eq(400)
      end

      it "fails with nonexistent init script tag" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          init: ["nonexistent@99"]
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "fails with invalid init ref format" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          init: ["bad-format"]
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "fails with --keep without --from" do
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          umi: "ubuntu-noble",
          keep: ["secrets"]
        }.to_json

        expect(last_response.status).to eq(400)
      end
    end

    describe "scale" do
      before do
        ap.update(
          umi_id: SecureRandom.uuid,
          umi_ref: "ubuntu-noble",
          vm_size: "standard-2"
        )
      end

      it "sets desired_count when scaling to current count" do
        # Add a member first so current == 1
        AppProcessMember.create(app_process_id: ap.id, vm_id: vm.id, ordinal: 0, state: "active")

        # Scale to count=1 (same as current, no VMs created)
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/scale", {
          count: 1
        }.to_json

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["desired_count"]).to eq(1)
      end

      it "refuses scale down" do
        ap.update(desired_count: 2)
        AppProcessMember.create(app_process_id: ap.id, vm_id: vm.id, ordinal: 0, state: "active")

        nic2 = Nic.create(name: "nic-2", private_subnet_id: ps.id, mac: "00:00:00:00:00:02", private_ipv4: "1.1.1.1", private_ipv6: "2001:db8::2", state: "active")
        vm2 = create_vm(name: "test-vm-2", project_id: project.id, location_id: Location[display_name: TEST_LOCATION].id)
        nic2.update(vm_id: vm2.id)
        AppProcessMember.create(app_process_id: ap.id, vm_id: vm2.id, ordinal: 1, state: "active")

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/scale", {
          count: 1
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "refuses when UMI not set" do
        ap.update(umi_id: nil, umi_ref: nil)

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/scale", {
          count: 2
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "refuses when fleet is heterogeneous" do
        tag1 = InitScriptTag.create(project_id: project.id, name: "v1", version: 1, init_script: "v1")
        tag2 = InitScriptTag.create(project_id: project.id, name: "v1", version: 2, init_script: "v2")

        # Set template to tag2
        AppProcessInit.create(app_process_id: ap.id, init_script_tag_id: tag2.id, ordinal: 0)

        # Create member with tag1 (mismatched)
        member = AppProcessMember.create(app_process_id: ap.id, vm_id: vm.id, ordinal: 0, state: "active")
        AppMemberInit.create(app_process_member_id: member.id, init_script_tag_id: tag1.id)

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/scale", {
          count: 3
        }.to_json

        expect(last_response.status).to eq(400)
      end
    end

    describe "releases" do
      it "returns empty release history" do
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/releases"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["items"]).to eq([])
      end

      it "returns release history after set" do
        # Set UMI to create a release
        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/set", {
          umi: "ubuntu-noble"
        }.to_json
        expect(last_response.status).to eq(200)

        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}/releases"

        expect(last_response.status).to eq(200)
        parsed = JSON.parse(last_response.body)
        expect(parsed["items"].length).to eq(1)
        expect(parsed["items"][0]["release_number"]).to eq(1)
        expect(parsed["items"][0]["action"]).to eq("set")
      end
    end

    describe "delete" do
      it "deletes app process" do
        delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/#{ap.flat_name}"

        expect(last_response.status).to eq(204)
        expect(AppProcess[ap.id]).to be_nil
      end

      it "returns 204 for nonexistent app on delete" do
        delete "/project/#{project.ubid}/location/#{TEST_LOCATION}/app/nonexistent"

        expect(last_response.status).to eq(204)
      end
    end

    describe "authorization" do
      it "rejects access to other project" do
        # PAT is scoped to `project`, so accessing a different project returns 401
        get "/project/#{project_wo_permissions.ubid}/location/#{TEST_LOCATION}/app"
        expect(last_response.status).to eq(401)
      end

      it "rejects create on other project" do
        post "/project/#{project_wo_permissions.ubid}/location/#{TEST_LOCATION}/app/myapp-web", {}.to_json
        expect(last_response.status).to eq(401)
      end

      it "rejects show on other project" do
        ap_unauth = AppProcess.create(
          group_name: "myapp",
          name: "web",
          project_id: project_wo_permissions.id,
          location_id: Location[display_name: TEST_LOCATION].id
        )

        get "/project/#{project_wo_permissions.ubid}/location/#{TEST_LOCATION}/app/#{ap_unauth.flat_name}"
        expect(last_response.status).to eq(401)
      end

      it "rejects delete on other project" do
        ap_unauth = AppProcess.create(
          group_name: "myapp",
          name: "web",
          project_id: project_wo_permissions.id,
          location_id: Location[display_name: TEST_LOCATION].id
        )

        delete "/project/#{project_wo_permissions.ubid}/location/#{TEST_LOCATION}/app/#{ap_unauth.flat_name}"
        expect(last_response.status).to eq(401)
      end
    end
  end
end
