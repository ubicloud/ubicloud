# frozen_string_literal: true

RSpec.describe SecretStore do
  let(:project) { Project.create(name: "test") }
  let(:secret_store) { described_class.create(project_id: project.id, name: "my-store") }

  it "has a ubid with the ss prefix" do
    expect(secret_store.ubid).to start_with("ss")
  end

  it "has a path" do
    expect(secret_store.path).to eq("/secret-store/#{secret_store.ubid}")
  end

  it "rejects invalid names" do
    ss = described_class.new(project_id: project.id, name: "Invalid Name")
    expect(ss.valid?).to be false
    expect(ss.errors[:name]).not_to be_nil
  end

  it "destroys its secrets when destroyed" do
    secret = Secret.create(secret_store_id: secret_store.id, key: "k", value: "v")
    secret_store.destroy
    expect(Secret[secret.id]).to be_nil
  end

  it "removes applied object tags when destroyed" do
    tag = ObjectTag.create(project_id: project.id, name: "tag")
    tag.add_member(secret_store.id)
    expect(DB[:applied_object_tag].where(object_id: secret_store.id).count).to eq(1)

    secret_store.destroy
    expect(DB[:applied_object_tag].where(object_id: secret_store.id).count).to eq(0)
  end

  it "is a valid object tag member" do
    expect(ObjectTag.valid_member?(project.id, secret_store)).to be true
    expect(ObjectTag.valid_member?("00000000-0000-0000-0000-000000000000", secret_store)).to be false
  end

  it "is listed among the object tag options for a project" do
    secret_store
    expect(ObjectTag.options_for_project(project)).to have_key("SecretStore")
  end
end
