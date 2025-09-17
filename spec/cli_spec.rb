# frozen_string_literal: true

require_relative "spec_helper"

require "puma/cli"
require "nio"
require "open3"
require "rbconfig"

Gem.ruby # force early loading to work in frozen specs

# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "bin/ubi" do
  # rubocop:enable RSpec/DescribeClass

  # rubocop:disable RSpec/BeforeAfterAll
  # We only want one server for all tests.  Spinning up a separate
  # thread/server for each test would be very slow.  Doing this is
  # safe, as we are not leaking state between tests (the server is
  # stateless and the web app it serves is a frozen Roda app).
  before(:all) do
    port = 8484
    queue = Queue.new
    @server = Puma::CLI.new(["-s", "-e", "test", "-b", "tcp://localhost:#{port}", "-t", "1:1", "spec/cli_config.ru"])
    @server.launcher.events.after_booted { queue.push(nil) }
    @server_thread = Thread.new do
      @server.launcher.run
    end
    queue.pop
    @prog = ENV["UBI_CMD"] || "bin/ubi"
    @env = {
      "UBI_URL" => "http://localhost:#{port}/cli",
      "UBI_TOKEN" => "a",
      "UBI_SSH" => "/bin/echo",
      "UBI_PG_DUMPALL" => "/bin/echo",
      "UBI_PSQL" => RbConfig.ruby
    }.freeze
    @debug_env = @env.merge("UBI_DEBUG" => "1")
    @skip_leaked_thread_check = true
  end

  after(:all) do
    @server.launcher.send(:stop)
    @skip_leaked_thread_check = false
    @server_thread.join(5)
  end
  # rubocop:enable RSpec/BeforeAfterAll

  it "returns error if there is no UBI_TOKEN provided" do
    o, e, s = Open3.capture3(@env.merge("UBI_TOKEN" => nil), @prog, "foo")
    expect(o).to eq ""
    expect(e).to eq "! Personal access token must be provided in UBI_TOKEN env variable for use\n"
    expect(s.exitstatus).to eq 1
  end

  it "shows error if invalid token is used" do
    o, e, s = Open3.capture3(@env.merge("UBI_TOKEN" => "b"), @prog, "foo")
    expect(o).to eq ""
    expect(e).to eq "invalid token\n"
    expect(s.exitstatus).to eq 1
  end

  it "prints response body to stdout on success" do
    o, e, s = Open3.capture3(@env, @prog, "foo")
    expect(o).to eq "foo"
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "includes sent argv when using UBI_DEBUG" do
    o, e, s = Open3.capture3(@debug_env, @prog, "foo")
    expect(o).to match(/\A(\[:)?sending(, "|: \[)foo"?\]\nfoo\z/)
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "sends expected headers" do
    o, e, s = Open3.capture3(@env, @prog, "headers")
    expect(o).to eq "close application/json text/plain Bearer: a"
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "sends version header" do
    o, e, s = Open3.capture3(@env, @prog, "version")
    expect(o).to match(UbiCli::UBI_VERSION_REGEXP)
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "prints response body to stderr on failure" do
    o, e, s = Open3.capture3(@env, @prog, "error", "foo")
    expect(o).to eq ""
    expect(e).to eq "error foo\n"
    expect(s.exitstatus).to eq 1
  end

  it "handles valid confirmations" do
    o, e, s = Open3.capture3(@env, @prog, "confirm", "foo", stdin_data: "valid")
    expect(o).to eq "Pre-Confirm\nTest-Confirm-Prompt: valid-confirm: foo"
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "includes both argvs when using UBI_DEBUG for confirmations" do
    o, e, s = Open3.capture3(@debug_env, @prog, "confirm", "foo", stdin_data: "valid")
    expect(o).to match(/
      sending.*confirm.*foo"?\]\n
      Pre-Confirm\n
      Test-Confirm-Prompt:\ .*sending.*--confirm.*valid.*confirm.*foo"?\]\n
      valid-confirm:\ foo\z
    /x)
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "handles invalid confirmations" do
    o, e, s = Open3.capture3(@env, @prog, "confirm", "foo", stdin_data: "invalid")
    expect(o).to eq "Pre-Confirm\nTest-Confirm-Prompt: "
    expect(e).to eq "invalid-confirm: foo\n"
    expect(s.exitstatus).to eq 1
  end

  it "does not recurse confirmation even if requested" do
    o, e, s = Open3.capture3(@env, @prog, "confirm", "foo", stdin_data: "recurse")
    expect(o).to eq "Pre-Confirm\nTest-Confirm-Prompt: "
    expect(e).to eq "! Invalid server response, repeated confirmation attempt\n"
    expect(s.exitstatus).to eq 1
  end

  it "executes supported program" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "ssh", "dash2", "foo")
    expect(o).to eq "foo --\n"
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "uses exit status of executed program" do
    o, e, s = Open3.capture3(@env.merge("UBI_SSH" => "false"), @prog, "exec", "ssh", "dash2", "foo")
    expect(o).to eq ""
    expect(e).to eq ""
    expect(s.exitstatus).to eq 1
  end

  it "executes supported program with new argument after --" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "ssh", "new-after", "foo")
    expect(o).to eq "foo -- new\n"
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "includes PGPASSWORD in environment for pg-related commands if ubi-pgpassword response header is present" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "psql", "psql", "-e", "ARGV.unshift(ENV['PGPASSWORD']); puts ARGV.join(' ')")
    expect(o).to eq "test-pg-pass new\n"
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "does not execute supported program with new argument before --" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "ssh", "new-before", "foo")
    expect(o).to eq ""
    expect(e).to eq "! Invalid server response, argument before '--' not in submitted argv\n"
    expect(s.exitstatus).to eq 1
  end

  it "shows executed commands when using UBI_DEBUG" do
    o, e, s = Open3.capture3(@debug_env, @prog, "exec", "ssh", "dash2", "foo")
    expect(o).to match(/
      sending.*exec.*ssh.*dash2.*foo"?\]\n
      .*exec.*\/bin\/echo.*foo.*--"?\]\n
      foo\ --\n\z
    /x)
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "shows failing argv for invalid execution when using UBI_DEBUG" do
    o, e, s = Open3.capture3(@debug_env, @prog, "exec", "ssh", "new-before", "foo")
    expect(o).to match(/
      sending.*exec.*ssh.*new-before.*foo"?\]\n
      .*failure.*\/bin\/echo.*foo.*new.*--"?\]\n?\z
    /x)
    expect(e).to eq "! Invalid server response, argument before '--' not in submitted argv\n"
    expect(s.exitstatus).to eq 1
  end

  it "does not execute invalid program" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "invalid", "dash2", "foo")
    expect(o).to eq ""
    expect(e).to eq "! Invalid server response, unsupported program requested\n"
    expect(s.exitstatus).to eq 1
  end

  it "does not execute program not in origin argv" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "ssh", "prog-switch", "foo")
    expect(o).to eq ""
    expect(e).to eq "! Invalid server response, not executing program not in original argv\n"
    expect(s.exitstatus).to eq 1
  end

  it "does not execute program without --" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "ssh", "as-is", "foo")
    expect(o).to eq ""
    expect(e).to eq "! Invalid server response, no '--' in returned argv\n"
    expect(s.exitstatus).to eq 1
  end

  it "allows pg_dumpall program without -- with -d" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "pg_dumpall", "newd", "foo")
    expect(o).to eq "foo -dnew\n"
    expect(e).to eq ""
    expect(s.exitstatus).to eq 0
  end

  it "does not execute program with multiple new arguments" do
    o, e, s = Open3.capture3(@env, @prog, "exec", "ssh", "new2", "foo")
    expect(o).to eq ""
    expect(e).to eq "! Invalid server response, multiple arguments not in submitted argv\n"
    expect(s.exitstatus).to eq 1
  end
end
