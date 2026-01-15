# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli sk destroy" do
  before do
    cli(%w[sk spk create] << "a a")
    @ssh_public_key = SshPublicKey.first
  end

  it "destroys SSH public key directly if -f option is given" do
    expect(cli(%w[sk spk destroy -f])).to eq "SSH public key has been removed\n"
    expect(@ssh_public_key).not_to be_exist
  end

  it "asks for confirmation if -f option is not given" do
    expect(cli(%w[sk spk destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this SSH public key is not recoverable.
      Enter the following to confirm destruction of the SSH public key: #{@ssh_public_key.name}
    END
    expect(@ssh_public_key).to be_exist
  end

  it "works on correct confirmation" do
    expect(cli(%w[--confirm spk sk spk destroy])).to eq "SSH public key has been removed\n"
    expect(@ssh_public_key).not_to be_exist
  end

  it "fails on incorrect confirmation" do
    expect(cli(%w[--confirm foo sk spk destroy], status: 400)).to eq "! Confirmation of SSH public key name not successful.\n"
    expect(@ssh_public_key).to be_exist
  end
end
