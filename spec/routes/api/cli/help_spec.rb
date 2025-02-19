# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "cli help" do
  it "shows help for top level command with no arguments" do
    expect(cli(%w[help])).to eq <<~OUTPUT
      Usage: ubi [options] [subcommand [subcommand-options] ...]

      Options:
              --version                    show program version
              --help                       show program help
              --confirm=confirmation       confirmation value (not for direct use)

      Subcommands: help pg vm
    OUTPUT
  end

  it "shows help for specific command if given" do
    expect(cli(%w[help help])).to eq <<~OUTPUT
      Usage: ubi help [options] [command [subcommand]]

      Options:
          -r, --recursive                  also show documentation for all subcommands of command
          -u, --usage                      only show usage
    OUTPUT
  end

  it "shows help for specific subcommand if given" do
    expect(cli(%w[help vm ssh])).to eq <<~OUTPUT
      Usage: ubi vm location/(vm-name|_vm-ubid) [options] ssh [ssh-options --] [remote-cmd [remote-cmd-arg ...]]
    OUTPUT
  end

  it "shows only usage if the -u flag is given" do
    expect(cli(%w[help -u help])).to eq <<~OUTPUT
      Usage: ubi help [options] [command [subcommand]]
    OUTPUT
  end

  it "shows help for all subcommands of command if -r is given" do
    expect(cli(%w[help -r vm])).to include <<~OUTPUT
      Usage: ubi vm location/vm_name create [options] public_key

      Options:
          -6, --ipv6-only                  do not enable IPv4
    OUTPUT
  end

  it "shows usage for all subcommands of command if -ru is given" do
    expect(cli(%w[help -ru vm])).to include <<~OUTPUT
      Usage: ubi vm list [options]
      Usage: ubi vm location/vm_name create [options] public_key
    OUTPUT
  end

  it "shows error and help for top level if top level command invalid" do
    expect(cli(%w[help foo], status: 400)).to eq <<~OUTPUT
      invalid command: foo

      Usage: ubi [options] [subcommand [subcommand-options] ...]

      Options:
              --version                    show program version
              --help                       show program help
              --confirm=confirmation       confirmation value (not for direct use)

      Subcommands: help pg vm
    OUTPUT
  end

  it "shows error and help for nested command if there is a partial match" do
    expect(cli(%w[help vm ssh foo], status: 400)).to eq <<~OUTPUT
      invalid command: vm ssh foo

      Usage: ubi vm location/(vm-name|_vm-ubid) [options] ssh [ssh-options --] [remote-cmd [remote-cmd-arg ...]]
    OUTPUT
  end
end
