# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AccessControlEntry do
  it "enforces subject, action, and object are valid and related to project" do
    account = Account.create(email: "test@example.com", status_id: 2)
    project = Project.create(name: "Test")
    account.add_project(project)
    project_id = project.id

    ace = described_class.new
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(project_id: ["is not present"], subject_id: ["is not present"])

    ace.project_id = project.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not present"])

    ace.subject_id = account.id
    expect(ace.valid?).to be true

    account2 = Account.create(email: "test2@example.com", status_id: 2)
    ace.subject_id = account2.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not related to this project"])

    ace.subject_id = ApiKey.create_personal_access_token(account, project:).id
    expect(ace.valid?).to be true

    # Backwards compatibility for old TYPE_ETC ubid (etkjnpyp1dst3n9d2mct7s71rh in this example)
    ace.subject_id = ApiKey.create(owner_table: "accounts", owner_id: account.id, used_for: "api", project_id: project.id) { |api_key| api_key.id = "9cab6f58-2dce-85da-aa5a-2a3347c9c388" }.id
    expect(ace.valid?).to be true

    project2 = Project.create(name: "Test-2")
    ace.subject_id = ApiKey.create_personal_access_token(account2, project: project2).id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not related to this project"])

    account.add_project(project2)
    ace.subject_id = SubjectTag.create(project_id: project2.id, name: "V").id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(subject_id: ["is not related to this project"])

    ace.subject_id = SubjectTag.create(project_id:, name: "V").id
    expect(ace.valid?).to be true

    ace.action_id = ActionType::NAME_MAP["Project:view"]
    expect(ace.valid?).to be true

    ace.action_id = ActionTag.create(project_id: project2.id, name: "V").id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(action_id: ["is not related to this project"])

    ace.action_id = ActionTag.create(project_id:, name: "V").id
    expect(ace.valid?).to be true

    ace.object_id = ObjectTag.create(project_id: project2.id, name: "V").id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    ace.object_id = project2.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    ace.object_id = project.id
    expect(ace.valid?).to be true

    firewall = Firewall.create(location_id: Location::HETZNER_FSN1_ID, project_id: project2.id)
    ace.object_id = firewall.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    firewall.update(project_id: project.id)
    expect(ace.valid?).to be true

    ace.object_id = ApiKey.create_inference_api_key(project2).id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    ace.object_id = ApiKey.create_inference_api_key(project).id
    expect(ace.valid?).to be true

    private_subnet_id = PrivateSubnet.create(
      name: "",
      net6: "fd1b:9793:dcef:cd0a:c::/79",
      net4: "10.9.39.5/32",
      project_id: project2.id,
      location_id: Location::HETZNER_FSN1_ID
    ).id
    load_balancer_id = LoadBalancer.create(
      name: "",
      private_subnet_id:,
      project_id: project2.id,
      health_check_endpoint: ""
    ).id
    LoadBalancerPort.create(
      load_balancer_id:,
      src_port: 1024,
      dst_port: 1025
    )
    inference_endpoint = InferenceEndpoint.create(
      location_id: Location::HETZNER_FSN1_ID,
      boot_image: "",
      name: "",
      vm_size: "",
      model_name: "",
      storage_volumes: "{}",
      engine: "",
      engine_params: "",
      replica_count: 1,
      project_id: project2.id,
      load_balancer_id:,
      private_subnet_id:
    )
    ace.object_id = inference_endpoint.id
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(object_id: ["is not related to this project"])

    inference_endpoint.update(project_id:)
    expect(ace.valid?).to be true

    ace.object_id = ObjectTag.create(project_id:, name: "V").id
    expect(ace.valid?).to be true

    ace.subject_id = ace.action_id = ace.object_id
    ace.object_id = described_class.generate_uuid
    expect(ace.valid?).to be false
    expect(ace.errors).to eq(
      subject_id: ["is not related to this project"],
      action_id: ["is not related to this project"],
      object_id: ["is not related to this project"]
    )
  end
end
