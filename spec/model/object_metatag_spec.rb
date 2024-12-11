# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe ObjectMetatag do
  let(:project) { Project.create_with_id(name: "test") }
  let(:tag) { ObjectTag.create_with_id(project_id: project.id, name: "T") }
  let(:metatag) { tag.metatag }

  it "can be created via ObjectTag#metatag" do
    expect(tag.metatag).to be_a(described_class)
  end

  it ".to_meta should convert ubid from ObjectTag to ObjectMetatag" do
    ubid = described_class.to_meta(tag.ubid)
    expect(ubid).to start_with("t2")
    expect(ubid).to eq metatag.ubid
  end

  it ".from_meta should convert ubid from ObjectMetatag to ObjectTag" do
    ubid = described_class.from_meta(metatag.ubid)
    expect(ubid).to start_with("t0")
    expect(ubid).to eq tag.ubid
  end

  it ".from_meta_uuid should convert uuid from ObjectMetatag to ObjectTag" do
    id = described_class.from_meta_uuid(metatag.id)
    expect(UBID.from_uuidish(id).to_s).to start_with("t0")
    expect(id).to eq tag.id
  end

  it "works correctly with UBID.resolve_map" do
    map = {metatag.id => nil}
    UBID.resolve_map(map)
    expect(map.length).to eq 1
    expect(map[metatag.id]).to be_a(described_class)
  end

  it "works with Authorization.has_permission?" do
    account = Account.create_with_id(email: "test@example.com", status_id: 2)
    project = account.create_project_with_default_policy("Default", default_policy: false)
    tag = ObjectTag.create_with_id(project_id: project.id, name: "T")
    ace = AccessControlEntry.create_with_id(project_id: project.id, subject_id: account.id, object_id: tag.id)
    expect(Authorization.has_permission?(project.id, account.id, "ObjectTag:view", tag.metatag_uuid)).to be false
    ace.update(object_id: tag.metatag_uuid)
    expect(Authorization.has_permission?(project.id, account.id, "ObjectTag:view", tag.metatag_uuid)).to be true
  end

  it "#id should return metatag uuid" do
    id = metatag.id
    expect(UBID.from_uuidish(id).to_s).to start_with("t2")
    expect(id).to eq tag.metatag_uuid
  end

  it "#ubid should return metatag ubid" do
    ubid = metatag.ubid
    expect(ubid).to start_with("t2")
    expect(ubid).to eq tag.metatag_ubid
  end

  it "has references destroyed when related tag is destroyed" do
    account = Account.create_with_id(email: "test@example.com", status_id: 2)
    project = account.create_project_with_default_policy("Default", default_policy: false)
    tag = ObjectTag.create_with_id(project_id: project.id, name: "T")
    ot = ObjectTag.create_with_id(project_id: project.id, name: "S")
    AccessControlEntry.create_with_id(project_id: project.id, subject_id: account.id, object_id: tag.metatag_uuid)
    ot.add_object(tag.metatag_uuid)
    tag.destroy
    expect(DB[:applied_object_tag].all).to be_empty
    expect(AccessControlEntry.all).to be_empty
  end
end
