# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli sk rename" do
  it "renames SSH public key" do
    cli(%w[sk spk create] << "a a")
    ssh_public_key = SshPublicKey.first
    expect(ssh_public_key.name).to eq "spk"
    expect(ssh_public_key.public_key).to eq "a a"
    body = cli(%w[sk spk rename b])
    ssh_public_key.reload
    expect(ssh_public_key.name).to eq "b"
    expect(ssh_public_key.public_key).to eq "a a"
    expect(body).to eq "SSH public key with id #{ssh_public_key.ubid} renamed to b\n"
  end
end
