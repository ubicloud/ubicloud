# frozen_string_literal: true

require_relative "../../common/spec/shell_script_helper"

RSpec.describe "reboot-host" do
  include ShellScriptHelper

  def reboot_host(*args)
    run_script("host/bin/reboot-host", *args, stubs: {"cat" => "echo current-boot", "sudo" => ""})
  end

  it "fails without previous boot id" do
    result = reboot_host
    expect(result.status).to eq 1
    expect(result.out).to eq "expected previous_boot_id as argument\n"
    expect(result.calls).to eq ""
  end

  it "reboots when boot id is unchanged" do
    result = reboot_host("current-boot")
    expect(result.status).to eq 0
    expect(result.out).to eq ""
    expect(result.calls).to eq "cat /proc/sys/kernel/random/boot_id\nsudo systemctl reboot\n"
  end

  it "prints new boot id after reboot" do
    result = reboot_host("previous-boot")
    expect(result.status).to eq 0
    expect(result.out).to eq "current-boot"
    expect(result.calls).to eq "cat /proc/sys/kernel/random/boot_id\n"
  end
end
