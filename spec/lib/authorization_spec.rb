# frozen_string_literal: true

require "sequel/model"

RSpec.describe Authorization do
  let(:users) {
    [
      Account.create(email: "auth1@example.com"),
      Account.create(email: "auth2@example.com")
    ]
  }
  let(:projects) { (0..1).map { users[it].create_project_with_default_policy("project-#{it}") } }
  let(:vms) {
    (0..3).map do |index|
      ps = Prog::Vnet::SubnetNexus.assemble(projects[index / 2].id, name: "vm#{index}-ps", location_id: Location::HETZNER_FSN1_ID).subject
      Prog::Vm::Nexus.assemble("k y", projects[index / 2].id, name: "vm#{index}", private_subnet_id: ps.id)
    end.map(&:subject)
  }
  let(:pg) {
    Prog::Postgres::PostgresResourceNexus.assemble(project_id: projects[0].id, location_id: Location::HETZNER_FSN1_ID, name: "pg0", target_vm_size: "standard-2", target_storage_size_gib: 128).subject
  }

  after do
    users.each(&:destroy)
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(projects[0].id)
  end

  def add_separate_aces(policies, project_id: projects[0].id)
    ace_subjects, ace_actions, ace_objects = policies.values_at(:subjects, :actions, :objects)
    Array(ace_subjects).each do |subject_id|
      Array(ace_actions).each do |action|
        action_id = ActionType::NAME_MAP.fetch(action) { ActionTag[project_id: nil, name: action].id } if action
        Array(ace_objects).each do |object_id|
          AccessControlEntry.create(project_id:, subject_id:, action_id:, object_id:)
        end
      end
    end
  end

  def add_single_ace(policies, project_id: projects[0].id)
    ace_subjects, ace_actions, ace_objects = policies.values_at(:subjects, :actions, :objects)

    subject_tag = SubjectTag.create(project_id:, name: "S")
    Array(ace_subjects).each do |subject_id|
      subject_tag.add_subject(subject_id)
    end
    subject_tag = yield subject_tag if block_given?

    action_id = unless ace_actions == [nil]
      action_tag = ActionTag.create(project_id:, name: "A")
      Array(ace_actions).each_with_index do |action_id, i|
        action_id = ActionType::NAME_MAP.fetch(action_id) { ActionTag[project_id: nil, name: action_id].id }
        action_tag.add_action(action_id)
      end
      action_tag = yield action_tag if block_given?
      action_tag.id
    end

    object_id = unless ace_objects == [nil]
      object_tag = ObjectTag.create(project_id:, name: "A")
      Array(ace_objects).each do |object_id|
        object_tag.add_object(object_id)
      end
      object_tag = yield object_tag if block_given?
      object_tag.id
    end

    AccessControlEntry.create(project_id:, subject_id: subject_tag.id, action_id:, object_id:)
  end

  def add_single_ace_with_nested_tags(policies, project_id: projects[0].id)
    add_single_ace(policies, project_id:) do |tag|
      3.times do |i|
        old_tag = tag
        tag = tag.class.create(project_id: tag.project_id, name: i.to_s)
        tag.send(:"add_#{tag.class.name.delete_suffix("Tag").downcase}", old_tag.id)
      end
      tag
    end
  end

  # rubocop:disable RSpec/MissingExpectationTargetMethod
  describe "#matched_policies" do
    it "without specific object" do
      AccessControlEntry.dataset.destroy
      project_id = projects[0].id

      [
        [{}, SecureRandom.uuid, "Vm:view", 0],
        [{}, SecureRandom.uuid, ["Vm:view"], 0],
        [{}, users[0].id, "Vm:view", 0],
        [{}, users[0].id, ["Vm:view"], 0],
        [{subjects: users[0].id, actions: "Vm:all", objects: [nil]}, users[0].id, "Vm:view", 1],
        [{subjects: users[0].id, actions: "Vm:all", objects: [nil]}, users[0].id, "Postgres:view", 0],
        [{subjects: users[0].id, actions: "Member", objects: [nil]}, users[0].id, "Vm:view", 1],
        [{subjects: users[0].id, actions: "Member", objects: [nil]}, users[0].id, "Project:edit", 0],
        [{subjects: users[0].id, actions: "Vm:view", objects: [nil]}, users[0].id, "Vm:view", 1],
        [{subjects: users[0].id, actions: "Vm:view", objects: [nil]}, users[0].id, ["Vm:view", "Vm:create"], 1],
        [{subjects: users[0].id, actions: ["Vm:view", "Vm:delete"], objects: [nil]}, users[0].id, ["Vm:view", "Vm:create"], 1],
        [{subjects: users[0].id, actions: "Vm:view", objects: vms[0].id}, users[0].id, "Vm:view", 1],
        [{subjects: users[0].id, actions: "Vm:view", objects: [vms[0].id, vms[1].id]}, users[0].id, "Vm:view", 2],
        [{subjects: users[0].id, actions: "Vm:delete", objects: vms[0].id}, users[0].id, "Vm:view", 0],
        [{subjects: users[0].id, actions: %w[Vm:view Vm:delete], objects: vms[0].id}, users[0].id, "Vm:view", 1],
        [{subjects: users[0].id, actions: [nil], objects: vms[0].id}, users[0].id, "Vm:view", 1],
        [{subjects: users[0].id, actions: "Postgres:view", objects: pg.id}, users[0].id, "Postgres:edit", 0],
        [{subjects: users[0].id, actions: "Postgres:edit", objects: pg.id}, users[0].id, "Postgres:view", 0],
        [{subjects: users[0].id, actions: "Postgres:view", objects: pg.id}, users[0].id, "Postgres:view", 1]
      ].each do |policies, subject_id, actions, matched_count|
        DB.transaction(rollback: :always) do
          add_separate_aces(policies)
          expect(described_class.matched_policies(project_id, subject_id, actions).count).to eq(matched_count)
          expect(described_class.all_permissions(project_id, subject_id, nil) & Array(actions)).send((matched_count == 0) ? :to : :not_to, be_empty)
        end

        DB.transaction(rollback: :always) do
          add_single_ace(policies)
          expect(described_class.matched_policies(project_id, subject_id, actions).count).to eq((matched_count == 0) ? 0 : 1)
          expect(described_class.all_permissions(project_id, subject_id, nil) & Array(actions)).send((matched_count == 0) ? :to : :not_to, be_empty)
        end

        DB.transaction(rollback: :always) do
          add_single_ace_with_nested_tags(policies)
          expect(described_class.matched_policies(project_id, subject_id, actions).count).to eq((matched_count == 0) ? 0 : 1)
          expect(described_class.all_permissions(project_id, subject_id, nil) & Array(actions)).send((matched_count == 0) ? :to : :not_to, be_empty)
        end
      end
    end

    it "with specific object" do
      AccessControlEntry.dataset.destroy
      project_id = projects[0].id

      # Backwards compatibility for old TYPE_ETC ubid (etkjnpyp1dst3n9d2mct7s71rh in this example)
      api_key_id = "9cab6f58-2dce-85da-aa5a-2a3347c9c388"
      ApiKey.create_with_id(api_key_id, owner_table: "project", owner_id: project_id, used_for: "inference_endpoint", project_id:)

      [
        [{subjects: [users[0].id], actions: ["Vm:view"], objects: api_key_id}, users[0].id, "Vm:view", api_key_id, 1],
        [{}, SecureRandom.uuid, "Vm:view", UBID.from_uuidish(SecureRandom.uuid).to_s.sub(/\A../, "00"), 0],
        [{}, SecureRandom.uuid, ["Vm:view"], UBID.from_uuidish(SecureRandom.uuid).to_s.sub(/\A../, "00"), 0],
        [{}, SecureRandom.uuid, ["Vm:view"], vms[0].id, 0],
        [{}, users[0].id, ["Vm:view"], vms[0].id, 0],
        [{subjects: users[0].id, actions: "Vm:all", objects: [nil]}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: "Vm:all", objects: [nil]}, users[0].id, "Postgres:view", vms[0].id, 0],
        [{subjects: users[0].id, actions: "Member", objects: [nil]}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: "Member", objects: [nil]}, users[0].id, "Project:edit", vms[0].id, 0],
        [{subjects: users[0].id, actions: "Vm:view", objects: [nil]}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: "Vm:view", objects: [nil]}, users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [{subjects: [users[0].id], actions: ["Vm:view"], objects: [nil]}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: ["Vm:view", "Vm:delete"], objects: [nil]}, users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [{subjects: users[0].id, actions: "Vm:delete", objects: [nil]}, users[0].id, "Vm:view", vms[0].id, 0],
        [{subjects: [users[0].id], actions: ["Vm:view"], objects: [nil]}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: "Vm:view", objects: vms[0].id}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: "Vm:view", objects: [vms[0].id, vms[1].id]}, users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [{subjects: [users[0].id], actions: ["Vm:view"], objects: vms[0].id}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: ["Vm:view", "Vm:delete"], objects: vms[0].id}, users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [{subjects: users[0].id, actions: "Vm:delete", objects: vms[0].id}, users[0].id, "Vm:view", vms[0].id, 0],
        [{subjects: [users[0].id], actions: ["Vm:view"], objects: vms[0].id}, users[0].id, "Vm:view", vms[0].id, 1],
        [{subjects: users[0].id, actions: "Vm:view", objects: vms[1].id}, users[0].id, "Vm:view", vms[0].id, 0],
        [{subjects: [users[0].id], actions: ["Vm:view"], objects: vms[1].id}, users[0].id, "Vm:view", vms[0].id, 0],
        [{subjects: users[0].id, actions: ["Vm:view", "Vm:delete"], objects: vms[1].id}, users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 0],
        [{subjects: users[0].id, actions: "Vm:delete", objects: vms[1].id}, users[0].id, "Vm:view", vms[0].id, 0],
        [{subjects: [users[0].id], actions: ["Vm:view"], objects: vms[1].id}, users[0].id, "Vm:view", vms[0].id, 0]
      ].each do |policies, subject_id, actions, object_id, matched_count|
        DB.transaction(rollback: :always) do
          add_separate_aces(policies)
          expect(described_class.matched_policies(project_id, subject_id, actions, object_id).count).to eq(matched_count)
          expect(described_class.all_permissions(project_id, subject_id, object_id) & Array(actions)).send((matched_count == 0) ? :to : :not_to, be_empty)
        end

        DB.transaction(rollback: :always) do
          add_single_ace(policies)
          expect(described_class.matched_policies(project_id, subject_id, actions, object_id).count).to eq((matched_count == 0) ? 0 : 1)
          expect(described_class.all_permissions(project_id, subject_id, object_id) & Array(actions)).send((matched_count == 0) ? :to : :not_to, be_empty)
        end

        DB.transaction(rollback: :always) do
          add_single_ace_with_nested_tags(policies)
          expect(described_class.matched_policies(project_id, subject_id, actions, object_id).count).to eq((matched_count == 0) ? 0 : 1)
          expect(described_class.all_permissions(project_id, subject_id, object_id) & Array(actions)).send((matched_count == 0) ? :to : :not_to, be_empty)
        end
      end
    end
  end
  # rubocop:enable RSpec/MissingExpectationTargetMethod

  describe "#has_permission?" do
    it "returns true when has matched policies" do
      expect(described_class.has_permission?(projects[0].id, users[0].id, "Vm:view", vms[0].id)).to be(true)
    end

    it "works when arguments are model objects" do
      expect(described_class.has_permission?(projects[0], users[0], "Vm:view", vms[0])).to be(true)
    end

    it "returns false when has no matched policies" do
      AccessControlEntry.dataset.destroy
      expect(described_class.has_permission?(projects[0].id, users[0].id, "Vm:view", vms[0].id)).to be(false)
    end
  end

  describe "#authorize" do
    it "does not raise error when there existed a matching access control entry when using UUID object_id" do
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", vms[0].id) }.not_to raise_error
    end

    it "does not raise error when there existed a matching access control entry when using UBID object_id" do
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", vms[0].ubid) }.not_to raise_error
    end

    it "does not raise error when there existed a matching access control entry when object_id in in project" do
      st = SubjectTag.create(project_id: projects[0].id, name: "test")
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", projects[0].id) }.not_to raise_error
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", vms[0].id) }.not_to raise_error
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", st.id) }.not_to raise_error
    end

    it "raises error when has matched policies when object is in project" do
      st = SubjectTag.create(project_id: projects[1].id, name: "test")
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", projects[1].id) }.to raise_error Authorization::Unauthorized
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", vms[3].id) }.to raise_error Authorization::Unauthorized
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", st.id) }.to raise_error Authorization::Unauthorized
    end

    it "raises error when non-UBID/non-UUID is used" do
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", "some-garbage") }.to raise_error UBIDParseError
    end

    it "raises error when has no matched policies" do
      AccessControlEntry.dataset.destroy
      expect { described_class.authorize(projects[0].id, users[0].id, "Vm:view", vms[0].id) }.to raise_error Authorization::Unauthorized
    end
  end

  describe ".dataset_authorize" do
    it "returns authorized resources for user and project and action when user has full permissions" do
      vms
      expect(described_class.dataset_authorize(Vm.dataset, projects[0].id, users[0].id, "Vm:view").select_map(:id).sort).to eq([vms[0].id, vms[1].id].sort)
      expect(described_class.dataset_authorize(Vm.dataset, projects[0].id, users[1].id, "Vm:view").select_map(:id)).to be_empty
      expect(described_class.dataset_authorize(Vm.dataset, projects[1].id, users[0].id, "Vm:view").select_map(:id)).to be_empty
      expect(described_class.dataset_authorize(Vm.dataset, projects[1].id, users[1].id, "Vm:view").select_map(:id).sort).to eq([vms[2].id, vms[3].id].sort)
    end

    {
      add_separate_aces: "direct permissions",
      add_single_ace: "indirect permissions via tag",
      add_single_ace_with_nested_tags: "indirect permissions via nested tag"
    }.each do |method, desc|
      it "returns authorized resources for user and project and action when user has #{desc}" do
        vms
        AccessControlEntry.dataset.destroy
        send(method, {subjects: users[0].id, actions: "Vm:view", objects: vms[0].id})
        send(method, {subjects: users[1].id, actions: "Vm:view", objects: vms[3].id}, project_id: projects[1].id)

        expect(described_class.dataset_authorize(Vm.dataset, projects[0].id, users[0].id, "Vm:view").select_map(:id)).to eq([vms[0].id])
        expect(described_class.dataset_authorize(Vm.dataset, projects[0].id, users[1].id, "Vm:view").select_map(:id)).to be_empty
        expect(described_class.dataset_authorize(Vm.dataset, projects[1].id, users[0].id, "Vm:view").select_map(:id)).to be_empty
        expect(described_class.dataset_authorize(Vm.dataset, projects[1].id, users[1].id, "Vm:view").select_map(:id)).to eq([vms[3].id])
      end
    end
  end
end
