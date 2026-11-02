# frozen_string_literal: true

require_relative "../routes/api/spec_helper"
require "puma"
# Loading puma/server adds an accessor to Thread, so it must happen before
# a frozen run freezes Thread.
require "puma/server"

# Runs terraform and the provider against clover's API in this process.
# Puma only passes each request to the example's thread, which runs it
# through RACK_TEST_APP inside the example's transaction, as the route
# specs do.
module TerraformHarness
  ROOT = File.expand_path("../..", __dir__)
  TMP = File.join(ROOT, "tmp/terraform")
  DEADLINE = 30
  STOPPED = [503, {}, []].freeze
  QUEUE = Thread::Queue.new

  # The provider's UBICLOUD_ variables are removed, so that an engineer's
  # token cannot reach a provider block that the override file does not cover.
  TF_ENV = {
    "TF_CLI_CONFIG_FILE" => "#{TMP}/dev.tfrc", "TF_IN_AUTOMATION" => "1", "CHECKPOINT_DISABLE" => "1", "TF_INPUT" => "0",
    "TF_CLI_ARGS" => "-no-color", "TF_CLI_ARGS_apply" => "-auto-approve", "TF_CLI_ARGS_destroy" => "-auto-approve",
    "UBICLOUD_API_TOKEN" => nil, "UBICLOUD_API_ENDPOINT" => nil, "UBICLOUD_PROJECT_ID" => nil, "GOCOVERDIR" => "#{TMP}/cover/harness",
  }.freeze

  Error = Class.new(StandardError)

  # Generates and builds the provider each time the harness loads, so that
  # no example tests a stale binary. The generator runs in a separate
  # process, to keep it out of clover's.
  def self.build
    system(RbConfig.ruby, "-S", "rake", "terraform:generate", chdir: ROOT, exception: true)
    FileUtils.rm_rf("#{TMP}/cover/harness")
    FileUtils.mkdir_p(["#{TMP}/bin", "#{TMP}/cover/harness"])
    system({"GOTOOLCHAIN" => "local"}, "go", "build", "-cover", "-o", "#{TMP}/bin/terraform-provider-ubicloud", ".", chdir: "#{ROOT}/terraform/provider", exception: true)
    File.write("#{TMP}/dev.tfrc", <<~HCL)
      provider_installation {
        dev_overrides {
          "registry.terraform.io/ubicloud/ubicloud" = "#{TMP}/bin"
        }
        direct {}
      }
    HCL
  end

  # What examples_harness.rb needs of each generated resource type, read
  # by spec/terraform/types.rb in a separate process.
  def self.types
    @types ||= JSON.parse(IO.popen([RbConfig.ruby, "#{__dir__}/types.rb"], &:read)).tap do
      raise Error, "spec/terraform/types.rb failed" unless Process.last_status.success?
    end
  end

  def self.endpoint
    @endpoint ||= begin
      app = ->(env) { Thread::Queue.new.tap { QUEUE << [env, it] }.pop }
      puma = Puma::Server.new(app, nil, min_threads: 0, max_threads: 16, log_writer: Puma::LogWriter.null)
      puma.add_tcp_listener("127.0.0.1", 0)
      puma.run
      "http://127.0.0.1:#{puma.connected_ports.first}"
    end
  end

  # A request the API received. Its path is shown as an example writes it:
  # relative to the project and the default location, with the id of each
  # named object replaced by @ and the name the object had when the
  # request arrived.
  class Request
    attr_reader :command, :verb, :shown, :body, :fault
    attr_accessor :status, :response, :error

    def initialize(env, project, command)
      @command, @verb = command, env["REQUEST_METHOD"]
      @body = env["rack.input"].read.tap { env["rack.input"].rewind }
      segments = env["PATH_INFO"].delete_prefix("/project/#{project.ubid}").delete_prefix("/location/#{TEST_LOCATION}").delete_prefix("/").split("/")
      @shown = segments.map { (object = UBID.decode(it)).respond_to?(:name) ? "@#{object.name}" : it }.join("/")
    end

    def to_s = "#{verb} #{shown}"

    # The provider gets this answer instead of the API's.
    def answer(status, body = nil, headers = {})
      self.status = status
      @fault = [status, {"content-type" => "application/json", **headers}, [body ? JSON.generate(body) : ""]]
    end

    def line = [command, to_s, error ? "500 #{error.class}" : status, response&.dig("state")&.then { "state=#{it}" }, response&.dig("error", "message")].compact.join(" ")
  end

  # The requests of an example, or of one command, each as "VERB shown/path".
  Ledger = Struct.new(:entries) do
    def requests(pattern = "*") = entries.map(&:to_s).select { File.fnmatch?(pattern, it) }
    def mutations(pattern = "*") = requests(pattern).grep_v(/\AGET /)
  end

  Plan = Data.define(:output, :resources) do
    def actions = resources.filter_map { |rc| (a = rc["change"]["actions"]) != ["no-op"] && [rc["address"], (a.size == 2) ? :replace : a.first.to_sym] }.to_h
    def empty? = (actions.values - [:read]).empty?
    def inspect = "#<Plan #{output[/^  # .*?(?=^Plan:)/m] || "no changes"}>"
  end

  # The example's terraform working directory, whose state carries over
  # from one command to the next.
  class Workspace
    attr_reader :dir

    def initialize(example, dir, override)
      @example, @dir, @count = example, dir, 0
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      File.write("#{dir}/harness_override.tf", override)
    end

    def apply(hcl = nil, *flags) = command("apply", hcl, *flags)
    def destroy(*flags) = command("destroy", nil, *flags)
    def run(name, *args) = command(name, nil, *args)

    # With -detailed-exitcode, terraform exits 2 if the plan changes
    # anything, and only then is show -json needed for the actions.
    def plan(hcl = nil, *flags)
      command("plan", hcl, "-out=tfplan", "-detailed-exitcode", *flags, ok: [0, 2])
      Plan.new(@output, (@status.exitstatus == 2) ? show("tfplan").fetch("resource_changes", []) : [])
    end

    def state(address = nil) = values("values", address)

    # Each attribute that state marks sensitive is true, as terraform show
    # -json gives it, inside any list or object that holds it.
    def sensitive(address) = values("sensitive_values", address)

    private

    def values(key, address)
      all = show.dig("values", "root_module", "resources").to_a.to_h { [it["address"], it[key]] }
      address ? all.fetch(address) : all
    end

    def show(*args) = JSON.parse(IO.popen(TF_ENV, ["terraform", "show", "-json", *args], chdir: dir, &:read))

    # An exception inside the API is raised as itself, whatever terraform
    # did, since a request that makes the API raise is a fault.
    def command(name, hcl, *args, ok: [0])
      File.write("#{dir}/main.tf", hcl) if hcl
      label = "#{name}##{@count += 1}"
      log = format("%s/%02d-%s.log", dir, @count, name)
      first = @example.ledger.entries.size
      @status = @example.terraform([name, *args], dir, log, label)
      @output = File.read(log)
      requests = @example.ledger.entries.drop(first)
      requests.find(&:error)&.then { raise it.error }
      raise Error, "terraform #{label} exited #{@status.exitstatus}:\n#{@output[/^Error: .*/m] || @output}" unless ok.include?(@status.exitstatus)
      Ledger.new(requests)
    end
  end

  module DSL
    def tf
      @tf ||= begin
        example = RSpec.current_example
        id = project.ubid
        Workspace.new(self, "#{TMP}/runs/#{File.basename(example.file_path, ".rb")}-#{example.id[/\[(.*)\]/, 1].tr(":", "-")}", <<~HCL)
          terraform {
            required_providers {
              ubicloud = { source = "ubicloud/ubicloud" }
            }
          }

          provider "ubicloud" {
            api_endpoint  = "#{TerraformHarness.endpoint}"
            api_token     = "pat-#{@pat.ubid}-#{@pat.key}"
            project_id    = "#{id}"
            poll_interval = "10ms"
          }
        HCL
      end
    end

    # A project whose personal access token is in its Admin tag, made as
    # the API's route specs make one.
    def project = @project ||= login_api && project_with_default_policy(create_account(with_project: false), name: "terraform")
    def ledger = @ledger ||= Ledger.new([])
    def gates = @gates ||= []

    # RSpec's mock verification fails the example if the block never runs.
    def at(phase, pattern, &block)
      expect(block).to receive(:call).and_call_original
      gates << [phase, pattern, block]
    end

    # Runs terraform and serves each request it sends on this thread, until
    # terraform exits or the deadline passes. Returns terraform's exit
    # status. Requests left from an earlier command get a 503 first.
    def terraform(argv, dir, log, label)
      until QUEUE.empty?
        env, reply = QUEUE.pop
        reply << STOPPED if env.is_a?(Hash)
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
      pid = Process.spawn(TF_ENV, "terraform", *argv, chdir: dir, out: log, err: [:child, :out], in: File::NULL, pgroup: true)
      waiter = Thread.new { QUEUE << [:exit, Process.wait2(pid).last] }
      loop do
        case QUEUE.pop(timeout: [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
        in [:exit, status] then return status
        in [Hash => env, reply]
          begin
            answer = serve(env, label)
          ensure
            reply << (answer || STOPPED)
          end
        in nil then raise Error, "terraform #{label} did not finish within #{DEADLINE} s; the last request was\n#{ledger.entries.last&.line}"
        end
      end
    ensure
      kill(pid, waiter) if waiter
    end

    private

    # Kills terraform's process group after every command, so that no
    # provider outlives it to send a request later.
    def kill(pid, waiter)
      Process.kill(:KILL, -pid)
    rescue Errno::ESRCH
    ensure
      waiter.join
    end

    def serve(env, command)
      env["HTTP_HOST"] = "api.ubicloud.com"
      request = Request.new(env, project, command)
      ledger.entries << request
      gate(:request, request)
      return request.fault if request.fault

      response = call_api(env, request)
      gate(:response, request)
      request.fault || response
    end

    # An exception inside the API is answered with an empty 500, and the
    # command raises it once terraform has exited.
    def call_api(env, request)
      status, headers, body = RACK_TEST_APP.call(env)
      text = +""
      body.each { text << it }
      body.close if body.respond_to?(:close)
      request.status = status
      request.response = JSON.parse(text) unless text.empty?
      [status, headers, [text]]
    rescue => e
      request.status, request.error = 500, e
      [500, {}, []]
    end

    def gate(phase, request)
      gate = gates.find { |p, pattern| p == phase && File.fnmatch?(pattern, request.to_s) } or return
      gates.delete(gate).last.call(request)
    end

    def failure_lines
      ["# The last of the #{ledger.entries.size} requests the API received in this example:",
        *ledger.entries.last(40).map { "    #{it.line}" },
        *("# Kept for inspection: #{tf.dir.delete_prefix("#{ROOT}/")}" if @tf)]
    end
  end
end

TerraformHarness.build

RSpec.configure do |config|
  config.include TerraformHarness::DSL

  # Failure/Error quotes the first backtrace line in a project source
  # directory: the harness's, or clover's for an exception inside the API.
  # With no such directory, RSpec quotes the first line in a spec file it
  # loaded, which is the example's.
  config.project_source_dirs = []
  config.backtrace_exclusion_patterns << %r{/spec/terraform/spec_helper\.rb:}

  # Plan#inspect is terraform's diff, which RSpec would cut to 200 characters.
  config.expect_with(:rspec) { it.max_formatted_output_length = nil }

  config.before do
    @skip_leaked_thread_check = true
    Thread.current[:route_spec] = true
  end

  # Mocks are verified after this hook, so it cannot know whether the
  # example failed; RSpec prints these lines only for one that did.
  config.after { |example| example.metadata[:extra_failure_lines] = failure_lines }
end
