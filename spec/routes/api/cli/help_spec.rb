# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "cli help" do
  it "shows help for specific command if given" do
    expect(cli(%w[help help])).to eq <<~OUTPUT
      Get command help

      Usage:
          ubi help [options] [command [subcommand]]

      Options:
          -r, --recursive                  also show documentation for all subcommands of command
          -u, --usage                      only show usage
    OUTPUT
  end

  it "shows help for specific subcommand if given" do
    expect(cli(%w[help vm ssh])).to eq <<~OUTPUT
      Connect to a virtual machine using `ssh`

      Usage:
          ubi vm (location/vm-name | vm-id) [options] ssh [ssh-options --] [remote-cmd [remote-cmd-arg ...]]
    OUTPUT
  end

  it "shows only usage if the -u flag is given" do
    expect(cli(%w[help -u help])).to eq <<~OUTPUT
      ubi help [options] [command [subcommand]]
    OUTPUT
  end

  it "shows help for all subcommands of command if -r is given" do
    expect(cli(%w[help -r vm])).to include <<~OUTPUT
      Usage:
          ubi vm location/vm-name create [options] public_key

      Examples:
          ubi vm eu-central-h1/my-vm-name create "$(cat ~/.ssh/id_ed25519.pub)"
          ubi vm eu-central-h1/my-vm-name create "$(cat ~/.ssh/authorized_keys)"

      Options:
          -6, --ipv6-only                  do not enable IPv4
    OUTPUT
  end

  it "shows usage for all subcommands of command if -ru is given" do
    expect(cli(%w[help -ru vm])).to include <<~OUTPUT
      ubi vm list [options]
      ubi vm location/vm-name create [options] public_key
    OUTPUT
  end

  it "shows error and help for nested command if there is a partial match" do
    expect(cli(%w[help vm ssh foo], status: 400)).to eq <<~OUTPUT
      ! Invalid command: vm ssh foo

      Connect to a virtual machine using `ssh`

      Usage:
          ubi vm (location/vm-name | vm-id) [options] ssh [ssh-options --] [remote-cmd [remote-cmd-arg ...]]
    OUTPUT
  end
end
