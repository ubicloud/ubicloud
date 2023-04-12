# frozen_string_literal: true

RSpec.describe Authorization do
  let(:users) { [Account.create(email: "auth1@example.com"), Account.create(email: "auth2@example.com")] }
  let(:tag_spaces) { (0..1).map { users[_1].create_tag_space_with_default_policy("tag-space-#{_1}") } }
  let(:vms) { (0..3).map { Prog::Vm::Nexus.assemble("key", tag_spaces[_1 / 2].id, name: "vm#{_1}") }.map(&:vm) }
  let(:access_policy) { tag_spaces[0].access_policies.first }

  after do
    users.each(&:destroy)
  end

  describe "#matched_policies" do
    it "without specific object" do
      [
        [[], SecureRandom.uuid, "Vm:view", 0],
        [[], SecureRandom.uuid, ["Vm:view"], 0],
        [[], SecureRandom.uuid, ["Vm:view"], 0],
        [[], users[0].id, "Vm:view", 0],
        [[], users[0].id, ["Vm:view"], 0],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:view", objects: tag_spaces[0].hyper_tag_name}], users[0].id, "Vm:view", 4],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:view", objects: tag_spaces[0].hyper_tag_name}], users[0].id, ["Vm:view", "Vm:create"], 4],
        [[{subjects: [users[0].hyper_tag_name], powers: ["Vm:view"], objects: [tag_spaces[0].hyper_tag_name]}], users[0].id, "Vm:view", 4],
        [[{subjects: [users[0].hyper_tag_name, users[1].hyper_tag_name], powers: ["Vm:view", "Vm:delete"], objects: [tag_spaces[0].hyper_tag_name]}], users[0].id, ["Vm:view", "Vm:create"], 4],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:view", objects: vms[0].hyper_tag_name}], users[0].id, "Vm:view", 1],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:view", objects: vms.map(&:hyper_tag_name)}], users[0].id, "Vm:view", 2],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:delete", objects: vms[0].hyper_tag_name}], users[0].id, "Vm:view", 0]
      ].each do |policies, subject_id, powers, matched_count|
        access_policy.update(body: {acls: policies})
        expect(described_class.matched_policies(subject_id, powers).count).to eq(matched_count)
      end
    end

    it "with specific object" do
      [
        [[], SecureRandom.uuid, "Vm:view", SecureRandom.uuid, 0],
        [[], SecureRandom.uuid, ["Vm:view"], SecureRandom.uuid, 0],
        [[], SecureRandom.uuid, ["Vm:view"], vms[0].id, 0],
        [[], users[0].id, ["Vm:view"], vms[0].id, 0],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:view", objects: tag_spaces[0].hyper_tag_name}], users[0].id, "Vm:view", vms[0].id, 1],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:view", objects: tag_spaces[0].hyper_tag_name}], users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [[{subjects: [users[0].hyper_tag_name], powers: ["Vm:view"], objects: [tag_spaces[0].hyper_tag_name]}], users[0].id, "Vm:view", vms[0].id, 1],
        [[{subjects: [users[0].hyper_tag_name, users[1].hyper_tag_name], powers: ["Vm:view", "Vm:delete"], objects: [tag_spaces[0].hyper_tag_name]}], users[0].id, ["Vm:view", "Vm:create"], vms[0].id, 1],
        [[{subjects: users[0].hyper_tag_name, powers: "Vm:delete", objects: tag_spaces[0].hyper_tag_name}], users[0].id, "Vm:view", vms[0].id, 0],
        [[{subjects: [users[0].hyper_tag_name], powers: ["Vm:view"], objects: [tag_spaces[0].hyper_tag_name, tag_spaces[0].hyper_tag_name]}], users[0].id, "Vm:view", vms[0].id, 1]
      ].each do |policies, subject_id, powers, object_id, matched_count|
        access_policy.update(body: {acls: policies})
        expect(described_class.matched_policies(subject_id, powers, object_id).count).to eq(matched_count)
      end
    end
  end

  describe "#has_power?" do
    it "returns true when has matched policies" do
      expect(described_class.has_power?(users[0].id, "Vm:view", vms[0].id)).to be(true)
    end

    it "returns false when has no matched policies" do
      access_policy.update(body: [])
      expect(described_class.has_power?(users[0].id, "Vm:view", vms[0].id)).to be(false)
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

  describe "#authorized_resources" do
    it "returns resource ids when has matched policies" do
      ids = [vms[0].id, vms[1].id, tag_spaces[0].id, users[0].id]
      expect(described_class.authorized_resources(users[0].id, "Vm:view").sort).to eq(ids.sort)
    end

    it "returns no resource ids when has no matched policies" do
      access_policy.update(body: [])
      expect(described_class.authorized_resources(users[0].id, "Vm:view")).to eq([])
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
      expect(users[0].hyper_tag_name).to eq("User/auth1@example.com")
      expect(vms[0].hyper_tag_name).to eq("Vm/vm0")
      expect(tag_spaces[0].hyper_tag_name).to eq("TagSpace/tag-space-0")
    end

    it "hyper_tag methods" do
      tag_space = TagSpace.create(name: "test")
      expect(tag_space.hyper_tag(tag_space)).to be_nil

      tag = tag_space.create_hyper_tag(tag_space)
      expect(tag_space.hyper_tag(tag_space)).to exist

      vms.each { _1.tag(tag) }
      expect(AppliedTag.where(access_tag_id: tag.id).count).to eq(4)

      tag_space.delete_hyper_tag(tag_space)
      expect(tag_space.hyper_tag(tag_space)).to be_nil
      expect(AppliedTag.where(access_tag_id: tag.id).count).to eq(0)
    end

    it "associate/dissociate with tag space" do
      tag_space = TagSpace.create(name: "test")
      tag_space.associate_with_tag_space(tag_space)
      users[0].associate_with_tag_space(tag_space)

      expect(tag_space.applied_access_tags.count).to eq(1)
      expect(users[0].applied_access_tags.count).to eq(2)

      users[0].dissociate_with_tag_space(tag_space)
      tag_space.dissociate_with_tag_space(tag_space)

      expect(tag_space.reload.applied_access_tags.count).to eq(0)
      expect(users[0].reload.applied_access_tags.count).to eq(0)
    end

    it "does not associate/dissociate with nil tag space" do
      tag_space = TagSpace.create(name: "test")
      expect(tag_space.associate_with_tag_space(nil)).to be_nil
      expect(tag_space.applied_access_tags.count).to eq(0)

      expect(tag_space.dissociate_with_tag_space(nil)).to be_nil
      expect(tag_space.applied_access_tags.count).to eq(0)
    end
  end

  describe "#TaggableMethods" do
    it "can tag" do
      tag = tag_spaces[1].hyper_tag(tag_spaces[1])
      expect(vms[0].applied_access_tags.include?(tag)).to be(false)
      vms[0].tag(tag)
      expect(vms[0].reload.applied_access_tags.include?(tag)).to be(true)
    end

    it "can untag" do
      tag = tag_spaces[0].hyper_tag(tag_spaces[0])
      expect(vms[0].applied_access_tags.include?(tag)).to be(true)
      vms[0].untag(tag)
      expect(vms[0].reload.applied_access_tags.include?(tag)).to be(false)
    end
  end
end
