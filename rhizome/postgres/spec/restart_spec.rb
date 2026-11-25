# frozen_string_literal: true

require_relative "../../common/spec/shell_script_helper"

RSpec.describe "postgres restart" do
  include ShellScriptHelper

  def restart(*args)
    run_script("postgres/bin/restart", *args, stubs: {"sudo" => ""})
  end

  it "fails with wrong number of arguments" do
    result = restart
    expect(result.status).to eq 1
    expect(result.err).to eq "Wrong number of arguments. Expected 1, Given 0\n"
    expect(result.calls).to eq ""
  end

  it "restarts postgres, pgbouncer, and metrics timer" do
    expect(restart("16").calls).to eq <<~CALLS
      sudo pg_ctlcluster 16 main restart
      sudo systemctl restart pgbouncer@*.service
      sudo systemctl restart postgres-metrics.timer
    CALLS
  end
end
