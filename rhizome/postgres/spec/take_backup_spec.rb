# frozen_string_literal: true

require_relative "../../common/spec/shell_script_helper"

RSpec.describe "take-backup" do
  include ShellScriptHelper

  def take_backup(*args)
    run_script("postgres/bin/take-backup", *args, stubs: {"sudo" => "", "systemd-run" => ""})
  end

  it "fails with wrong number of arguments" do
    [[], %w[16 50 extra]].each do |args|
      result = take_backup(*args)
      expect(result.status).to eq 1
      expect(result.err).to eq "Wrong number of arguments. Expected 1 or 2, Given #{args.size}\n"
      expect(result.calls).to eq ""
    end
  end

  it "pushes backup without cpu weight" do
    expected = "sudo -u postgres wal-g backup-push /dat/16/data --config /etc/postgresql/wal-g.env --verify\n"
    expect(take_backup("16").calls).to eq expected
    expect(take_backup("16", "0").calls).to eq expected
  end

  it "pushes backup in a scope with cpu weight" do
    expect(take_backup("17", "50").calls).to eq "systemd-run --scope --collect -p CPUWeight=50 sudo -u postgres wal-g backup-push /dat/17/data --config /etc/postgresql/wal-g.env --verify\n"
  end
end
