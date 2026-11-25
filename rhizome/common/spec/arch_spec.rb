# frozen_string_literal: true

require_relative "shell_script_helper"

RSpec.describe "arch" do
  include ShellScriptHelper

  def arch(machine)
    run_script("common/bin/arch", stubs: {"uname" => "echo #{machine}"})
  end

  it "maps arm machine names to arm64" do
    expect(arch("aarch64").out).to eq "arm64\n"
    expect(arch("arm64").out).to eq "arm64\n"
  end

  it "maps x86 machine names to x64" do
    expect(arch("x86_64").out).to eq "x64\n"
    expect(arch("amd64").out).to eq "x64\n"
    expect(arch("x64").out).to eq "x64\n"
  end

  it "fails on unknown machine names" do
    result = arch("riscv64")
    expect(result.status).to eq 1
    expect(result.out).to eq ""
    expect(result.err).to eq "BUG: could not detect architecture: riscv64\n"
  end
end
