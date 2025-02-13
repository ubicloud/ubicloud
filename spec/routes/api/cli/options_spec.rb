# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "cli" do
  it "errors if argv is not an array of strings" do
    expect(cli([1], status: 400)).to eq "Invalid request: No or invalid argv parameter provided"
    expect(cli("--version", status: 400)).to eq "Invalid request: No or invalid argv parameter provided"
  end

  it "errors if token is not provided" do
    header "Authorization", "Foo"
    expect(cli(%w[--version], status: 400)).to eq "Invalid request: No valid personal access token provided"
  end

  it "handles --version" do
    expect(cli(%w[--version])).to eq "0.0.0"
  end

  it "handles --help" do
    expect(cli(%w[--help])).to eq <<~OUTPUT
      Usage: ubi [options] [subcommand [subcommand_options] ...]

      Options:
              --version                    show program version
              --help                       show program help
              --confirm=confirmation       confirmation value (not for direct use)

      Subcommands: help pg vm
    OUTPUT
  end

  it "shows usage on invalid option" do
    expect(cli(%w[--foo], status: 400)).to eq <<~OUTPUT
      invalid option: --foo

      Usage: ubi [options] [subcommand [subcommand_options] ...]

      Options:
              --version                    show program version
              --help                       show program help
              --confirm=confirmation       confirmation value (not for direct use)

      Subcommands: help pg vm
    OUTPUT
  end
end
