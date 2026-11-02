# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ubicloud_ssh_public_key" do
  def key = <<~HCL
    resource "ubicloud_ssh_public_key" "laptop" {
      name       = "laptop"
      public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOT0eJ0n8m0KpQ alice@example.com"
    }
  HCL

  it "adopts the key by name when a proxy answers 502 after the API created it" do
    at(:response, "POST ssh-public-key") { it.answer(502) }
    tf.apply key

    expect(ledger.requests).to eq ["POST ssh-public-key", "GET ssh-public-key/laptop", "GET ssh-public-key/@laptop"]
    expect(SshPublicKey.where(project_id: project.id).count).to eq 1
    expect(tf.state("ubicloud_ssh_public_key.laptop")["id"]).to eq SshPublicKey.first(project_id: project.id).ubid
    expect(tf.plan).to be_empty
  end

  it "fails the create, and keeps no state, when the name is taken first" do
    SshPublicKey.create(project_id: project.id, name: "laptop", public_key: "ssh-ed25519 AAAA bob@example.com")

    expect { tf.apply key }.to raise_error(TerraformHarness::Error, /already taken/)
    expect(ledger.requests).to eq ["POST ssh-public-key"]
    expect(tf.state).to be_empty
  end

  it "raises an exception from inside the API as itself" do
    allow(Serializers::SshPublicKey).to receive(:serialize_internal).and_raise(RuntimeError, "boom")

    expect { tf.apply key }.to raise_error(RuntimeError, "boom")
  end
end
