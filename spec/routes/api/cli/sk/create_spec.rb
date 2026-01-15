# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli sk create" do
  it "creates SSH public key" do
    expect(SshPublicKey.count).to eq 0
    body = cli(%w[sk spk create] << "a a")
    expect(SshPublicKey.count).to eq 1
    ssh_public_key = SshPublicKey.first
    expect(ssh_public_key.name).to eq "spk"
    expect(ssh_public_key.public_key).to eq "a a"
    expect(body).to eq "SSH public key registered with id: #{ssh_public_key.ubid}\n"
  end
end
