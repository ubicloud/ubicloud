# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "cli" do
  it "errors if argv is not an array of strings" do
    expect(cli([1], status: 400)).to eq "! Invalid request: No or invalid argv parameter provided\n"
    expect(cli("version", status: 400)).to eq "! Invalid request: No or invalid argv parameter provided\n"
  end

  it "errors if token is not provided" do
    header "Authorization", "Foo"
    expect(cli(%w[version], status: 400)).to eq "! Invalid request: No valid personal access token provided\n"
  end

  it "handles version with a valid version" do
    expect(cli(%w[version])).to match(/\A\d+\.\d+\.\d+\n\z/)
  end

  it "handles version with an invalid version" do
    expect(cli(%w[version], env: {"HTTP_X_UBI_VERSION" => "bad"})).to eq "unknown\n"
    expect(cli(%w[version], env: {})).to eq "unknown\n"
  end

  it "logs CLI commands" do
    expect(Clog).to receive(:emit).with("cli command", cli_command: {argv: %w[version], project: @project.ubid})
    expect(cli(%w[version])).to match(/\A\d+\.\d+\.\d+\n\z/)
  end

  it "truncates long cli command arguments" do
    expect(Clog).to receive(:emit).with("cli command", cli_command: {argv: ["version", [26, "aaaaa", "aaaa"]], project: @project.ubid})
    expect(cli(["version", "a" * 26], status: 400)).to eq <<~END
       ! Invalid number of arguments for version subcommand (requires: 0, given: 1)

       Display CLI program version

       Usage:
           ubi version
    END
  end

  it "truncates long cli command argument lists" do
    expect(Clog).to receive(:emit).with("cli command", cli_command: {argv: ["version"] + ["a"] * 24 + [26], project: @project.ubid})
    expect(cli(["version"] + ["a"] * 25, status: 400)).to eq <<~END
       ! Invalid number of arguments for version subcommand (requires: 0, given: 25)

       Display CLI program version

       Usage:
           ubi version
    END
  end
end
