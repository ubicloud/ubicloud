# frozen_string_literal: true

require "sequel/model"

RSpec.describe Authorization do
  let(:users) {
    [
      Account.create_with_id(email: "auth1@example.com"),
      Account.create_with_id(email: "auth2@example.com")
    ]
  }
  let(:projects) { (0..1).map { users[_1].create_project_with_default_policy("project-#{_1}") } }
  let(:vms) {
    (0..3).map do |index|
      ps = Prog::Vnet::SubnetNexus.assemble(projects[index / 2].id, name: "vm#{index}-ps", location: "hetzner-fsn1").subject
      Prog::Vm::Nexus.assemble("key", projects[index / 2].id, name: "vm#{index}", private_subnet_id: ps.id)
    end.map(&:subject)
  }
  let(:pg) {
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: projects[0].id, location: "hetzner-fsn1", name: "pg0", target_vm_size: "standard-2", target_storage_size_gib: 128
    ).subject
  }
  let(:access_policy) { projects[0].access_policies.first }

  after do
    users.each(&:destroy)
  end

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(projects[0].id)
  end

  describe "#matched_policies" do
    it "without specific object" do
      [
        [[], SecureRandom.uuid, "Vm:view", 0],
        [[], SecureRandom.uuid, ["Vm:view"], 0],
        [[], SecureRandom.uuid, ["Vm:view"], 0],
        [[], users[0].id, "Vm:view", 0],
        [[], users[0].id, ["Vm:view"], 0],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:view", objects: projects[0].hyper_tag_name}], users[0].id, "Vm:view", 12],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:view", objects: projects[0].hyper_tag_name}], users[0].id, ["Vm:view", "Vm:create"], 12],
        [[{subjects: [users[0].hyper_tag_name], actions: ["Vm:view"], objects: [projects[0].hyper_tag_name]}], users[0].id, "Vm:view", 12],
        [[{subjects: [users[0].hyper_tag_name, users[1].hyper_tag_name], actions: ["Vm:view", "Vm:delete"], objects: [projects[0].hyper_tag_name]}], users[0].id, ["Vm:view", "Vm:create"], 12],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:view", objects: vms[0].hyper_tag_name(access_policy.project)}], users[0].id, "Vm:view", 1],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:view", objects: vms.map { _1.hyper_tag_name(access_policy.project) }}], users[0].id, "Vm:view", 2],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:delete", objects: vms[0].hyper_tag_name(access_policy.project)}], users[0].id, "Vm:view", 0],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:*", objects: vms[0].hyper_tag_name(access_policy.project)}], users[0].id, "Vm:view", 1],
        [[{subjects: users[0].hyper_tag_name, actions: "*", objects: vms[0].hyper_tag_name(access_policy.project)}], users[0].id, "Vm:view", 1],
        [[{subjects: users[0].hyper_tag_name, actions: "Postgres:Firewall:view", objects: pg.hyper_tag_name(access_policy.project)}], users[0].id, "Postgres:Firewall:delete", 0],
        [[{subjects: users[0].hyper_tag_name, actions: "Postgres:Firewall:edit", objects: pg.hyper_tag_name(access_policy.project)}], users[0].id, "Postgres:Firewall:view", 0]
      ].each do |policies, subject_id, actions, matched_count|
        access_policy.update(body: {acls: policies})
        expect(described_class.matched_policies(subject_id, actions).count).to eq(matched_count)
      end
    end

    it "with specific object" do
      [
        [[], SecureRandom.uuid, "Vm:view", SecureRandom.uuid, 0],
        [[], SecureRandom.uuid, ["Vm:view"], SecureRandom.uuid, 0],
        [[], SecureRandom.uuid, ["Vm:view"], vms[0].id, 0],
        [[], users[0].id, ["Vm:view"], vms[0].id, 0],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:view", objects: projects[0].hyper_tag_name}], users[0].id, "Vm:view", vms[0].id, 1],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:view", objects: projects[0].hyper_tag_name}], users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [[{subjects: [users[0].hyper_tag_name], actions: ["Vm:view"], objects: [projects[0].hyper_tag_name]}], users[0].id, "Vm:view", vms[0].id, 1],
        [[{subjects: [users[0].hyper_tag_name, users[1].hyper_tag_name], actions: ["Vm:view", "Vm:delete"], objects: [projects[0].hyper_tag_name]}], users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [[{subjects: users[0].hyper_tag_name, actions: "Vm:delete", objects: projects[0].hyper_tag_name}], users[0].id, "Vm:view", vms[0].id, 0],
        [[{subjects: [users[0].hyper_tag_name], actions: ["Vm:view"], objects: [projects[0].hyper_tag_name, projects[0].hyper_tag_name]}], users[0].id, "Vm:view", vms[0].id, 1]
      ].each do |policies, subject_id, actions, object_id, matched_count|
        access_policy.update(body: {acls: policies})
        expect(described_class.matched_policies(subject_id, actions, object_id).count).to eq(matched_count)
      end
    end
  end

  describe "#has_permission?" do
    it "returns true when has matched policies" do
      expect(described_class.has_permission?(users[0].id, "Vm:view", vms[0].id)).to be(true)
    end

    it "returns false when has no matched policies" do
      access_policy.update(body: [])
      expect(described_class.has_permission?(users[0].id, "Vm:view", vms[0].id)).to be(false)
    end
  end

  describe "#authorize" do
    it "not raises error when has matched policies" do
      expect { described_class.authorize(users[0].id, "Vm:view", vms[0].id) }.not_to raise_error
    end

    it "raises error when has no matched policies" do
      access_policy.update(body: [])
      expect { described_class.authorize(users[0].id, "Vm:view", vms[0].id) }.to raise_error Authorization::Unauthorized
    end
  end

  describe "#authorized_resources_dataset" do
    it "returns resource ids when has matched policies" do
      ids = [vms[0].id, vms[1].id, projects[0].id, users[0].id, vms[0].private_subnets[0].id, vms[1].private_subnets[0].id, vms[0].firewalls[0].id, vms[1].firewalls[0].id]
      expect(described_class.authorized_resources_dataset(users[0].id, "Vm:view").map(:tagged_id).sort).to eq(ids.sort)
    end

    it "returns no resource ids when has no matched policies" do
      access_policy.update(body: [])
      expect(described_class.authorized_resources_dataset(users[0].id, "Vm:view")).to be_empty
    end
  end

  describe "#expand_actions" do
    it "returns expanded actions" do
      [
        ["*", ["*"]],
        ["Vm:*", ["Vm:*", "*"]],
        ["Vm:view", ["Vm:view", "Vm:*", "*"]],
        [["Vm:view", "PrivateSubnet:view"], ["Vm:view", "PrivateSubnet:view", "Vm:*", "PrivateSubnet:*", "*"]]
      ].each do |actions, expected|
        expect(described_class.expand_actions(actions)).to match_array(expected)
      end
    end
  end

  describe "#ManagedPolicy" do
    it "apply" do
      expect(AccessPolicy[project_id: projects[0].id, name: "member", managed: true]).to be_nil
      described_class::ManagedPolicy::Member.apply(projects[0], [users[0], nil, users[1]])
      acl = AccessPolicy[project_id: projects[0].id, name: "member", managed: true].body["acls"].first
      expect(acl["subjects"]).to contain_exactly(users[0].hyper_tag_name)
      expect(acl["actions"]).to eq(["Vm:*", "PrivateSubnet:*", "Firewall:*", "Postgres:*", "Project:view", "Project:github"])
      expect(acl["objects"]).to eq(["project/#{projects[0].ubid}"])
      users[1].associate_with_project(projects[0])
      described_class::ManagedPolicy::Member.apply(projects[0], [users[1]], append: true)
      expect(AccessPolicy[project_id: projects[0].id, name: "member", managed: true].body["acls"].first["subjects"]).to contain_exactly(users[0].hyper_tag_name, users[1].hyper_tag_name)
      described_class::ManagedPolicy::Member.apply(projects[0], [])
      expect(AccessPolicy[project_id: projects[0].id, name: "member", managed: true].body["acls"].first["subjects"]).to eq([])
    end

    it "from_name" do
      expect(described_class::ManagedPolicy.from_name("admin")).to eq(described_class::ManagedPolicy::Admin)
      expect(described_class::ManagedPolicy.from_name("invalid")).to be_nil
    end
  end

  describe "#Dataset" do
    it "returns authorized resources" do
      ids = [vms[0].id, vms[1].id]
      expect(Vm.authorized(users[0].id, "Vm:view").select_map(:id).sort).to eq(ids.sort)
    end

    it "returns no authorized resources" do
      expect(Vm.authorized(users[0].id, "Vm:view").select_map(:id).sort).to eq([])
    end
  end

  describe "#HyperTagMethods" do
    it "hyper_tag_name" do
      expect(users[0].hyper_tag_name).to eq("user/auth1@example.com")
      p = vms[0].projects.first
      expect(vms[0].hyper_tag_name(p)).to eq("project/#{p.ubid}/location/eu-central-h1/vm/vm0")
      expect(projects[0].hyper_tag_name).to eq("project/#{projects[0].ubid}")
    end

    it "hyper_tag_name error" do
      c = Class.new(Sequel::Model) do
        include Authorization::HyperTagMethods
      end

      expect { c.new.hyper_tag_name }.to raise_error NoMethodError
    end

    it "hyper_tag methods" do
      project = Project.create_with_id(name: "test")
      expect(project.hyper_tag(project)).to be_nil

      tag = project.associate_with_project(project)
      expect(project.hyper_tag(project)).to exist

      vms.each { _1.tag(tag) }
      expect(AppliedTag.where(access_tag_id: tag.id).count).to eq(5)

      project.dissociate_with_project(project)
      expect(project.hyper_tag(project)).to be_nil
      expect(AppliedTag.where(access_tag_id: tag.id).count).to eq(0)
    end

    it "associate/dissociate with project" do
      project = Project.create_with_id(name: "test")
      project.associate_with_project(project)
      users[0].associate_with_project(project)

      expect(project.applied_access_tags.count).to eq(1)
      expect(users[0].applied_access_tags.count).to eq(4)

      users[0].dissociate_with_project(project)
      project.dissociate_with_project(project)

      expect(project.reload.applied_access_tags.count).to eq(0)
      expect(users[0].reload.applied_access_tags.count).to eq(2)
    end

    it "does not associate/dissociate with nil project" do
      project = Project.create_with_id(name: "test")
      expect(project.associate_with_project(nil)).to be_nil
      expect(project.applied_access_tags.count).to eq(0)

      expect(project.dissociate_with_project(nil)).to be_nil
      expect(project.applied_access_tags.count).to eq(0)
    end
  end

  describe "#TaggableMethods" do
    it "can tag" do
      tag = projects[1].hyper_tag(projects[1])
      expect(vms[0].applied_access_tags.include?(tag)).to be(false)
      vms[0].tag(tag)
      expect(vms[0].reload.applied_access_tags.include?(tag)).to be(true)
    end

    it "can untag" do
      tag = projects[0].hyper_tag(projects[0])
      expect(vms[0].applied_access_tags.include?(tag)).to be(true)
      vms[0].untag(tag)
      expect(vms[0].reload.applied_access_tags.include?(tag)).to be(false)
    end
  end
end
