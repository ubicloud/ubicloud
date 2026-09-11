# frozen_string_literal: true

require_relative "../spec_helper"
raise "test database doesn't end with test" if DB.opts[:database] && !/test\d*\z/.match?(DB.opts[:database])

require "puma"
require "open3"
require "erb"
require "json"
require "tmpdir"

require_relative "request_gate"
require_relative "../../lib/terraform_generator"
TerraformGenerator.load_definitions!
require_relative "database_janitor"

# Real terraform, real provider binary, real HTTP against an
# in-process puma serving the actual API - with concurrency made
# deterministic by RequestGate barriers and the world reset by
# DatabaseJanitor. Conventions (model by name, derived fixtures and
# gate paths) cover the CRUD baseline for every definition; the
# registry carries only per-resource control-plane hooks.
module TerraformHarness
  # Defaults: the generated provider module under this repo's gitignored
  # tmp/, and a tmp dir for the built binary. Both overridable by env.
  PROVIDER_REPO = ENV["UBICLOUD_TF_PROVIDER_REPO"] || File.expand_path("../../tmp/terraform-provider-ubicloud", __dir__)
  PROVIDER_BIN_DIR = ENV["UBICLOUD_TF_PROVIDER_BIN_DIR"] || File.expand_path("../../tmp/terraform-provider-bin", __dir__)
  PROVIDER_BIN = File.join(PROVIDER_BIN_DIR, "terraform-provider-ubicloud")
  FIXTURES = File.expand_path("fixtures", __dir__)
  LOCATION = "eu-central-h1"

  class << self
    attr_reader :port, :server_thread, :request_gate

    # Boot clover's API app in-process on an ephemeral port. The kernel
    # assigns the port (bind to 0), so parallel test workers never collide.
    def start_server!
      return @port if @port

      # The host_routing plugin dispatches on the Host header ("api.*" =>
      # :api branch). The provider connects to 127.0.0.1:<port>, so
      # normalize Host here, mirroring what the rack-test API specs do
      # with `header "Host", "api.ubicloud.com"`.
      host_normalizer = lambda do |env|
        env["HTTP_HOST"] = "api.ubicloud.com"
        Clover.app.call(env)
      end
      @request_gate = RequestGate.new(host_normalizer)

      before = Thread.list
      # min_threads == max_threads so the pool pre-spawns every worker
      # at boot; combined with puma's internal threads (reactor, reap,
      # trim, server), everything long-lived exists right here and can
      # be registered with the leaked-thread check in one shot.
      @server = Puma::Server.new(@request_gate, nil, min_threads: 4, max_threads: 4)
      @server.add_tcp_listener("127.0.0.1", 0)
      @port = @server.connected_ports.first
      @server_thread = @server.run
      sleep 0.1 until (Thread.list - before).count { it.name.to_s.include?("srv tp") } >= 4
      RSpec.configuration.register_expected_threads(*(Thread.list - before))
      @port
    end

    def stop_server!
      @server&.stop(true)
      @server = nil
      @port = nil
    end

    def endpoint
      "http://127.0.0.1:#{port}"
    end

    # Build the provider binary once per suite if absent.
    def ensure_provider_binary!
      return PROVIDER_BIN if File.executable?(PROVIDER_BIN)

      out, status = Open3.capture2e("go", "build", "-o", PROVIDER_BIN, ".", chdir: PROVIDER_REPO)
      raise "provider build failed:\n#{out}" unless status.success?
      PROVIDER_BIN
    end

    # CLI config pointing terraform at the locally built provider via
    # dev_overrides; no `terraform init` needed (or wanted).
    def write_cli_config(dir)
      path = File.join(dir, "dev.tfrc")
      File.write(path, <<~HCL)
        provider_installation {
          dev_overrides {
            "registry.terraform.io/ubicloud/ubicloud" = "#{PROVIDER_BIN_DIR}"
          }
          direct {}
        }
      HCL
      path
    end
  end

  # Per-example terraform working dir: renders an ERB fixture, runs
  # terraform against the in-process server, exposes plan/state JSON.
  class Runner
    attr_reader :dir

    def initialize(fixture:, vars:, env: {})
      @dir = Dir.mktmpdir("tfspec")
      @env = env
      @cli_config = TerraformHarness.write_cli_config(@dir)
      @template = fixture.respond_to?(:content) ? fixture.content : File.read(File.join(FIXTURES, fixture))
      tf = ERB.new(@template, trim_mode: "-").result_with_hash(vars)
      File.write(File.join(@dir, "main.tf"), tf)
    end

    def apply = run!("apply", "-auto-approve", "-no-color")
    def destroy = run!("destroy", "-auto-approve", "-no-color")

    def plan_json
      run!("plan", "-no-color", "-out=plan.tfplan")
      JSON.parse(run!("show", "-json", "plan.tfplan").stdout)
    end

    def state_json
      JSON.parse(run!("show", "-json").stdout)
    end

    def state_path = File.join(@dir, "terraform.tfstate")

    def state_resources
      state_json.dig("values", "root_module", "resources")
    end

    def cleanup
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
    end

    # Re-render the fixture in place (same working dir, same state):
    # the second apply becomes an update.
    def rewrite(vars)
      tf = ERB.new(@template, trim_mode: "-").result_with_hash(vars)
      File.write(File.join(@dir, "main.tf"), tf)
    end

    Result = Struct.new(:stdout, :stderr, :status) do
      def output = stdout + stderr
    end

    def run(*args)
      stdout, stderr, status = Open3.capture3(
        {
          "TF_CLI_CONFIG_FILE" => @cli_config,
          "TF_IN_AUTOMATION" => "1",
          "TF_INPUT" => "0",
          "CHECKPOINT_DISABLE" => "1",
          # Specs run at memory speed: the provider reads poll/timeout
          # tuning from env (decision 2e). Overridable per-runner.
          "UBICLOUD_POSTGRES_POLL_INTERVAL" => "25ms",
          "UBICLOUD_POSTGRES_CREATE_TIMEOUT" => "60s",
          "UBICLOUD_POSTGRES_DELETE_TIMEOUT" => "60s",
          "UBICLOUD_POSTGRES_UPGRADE_TIMEOUT" => "10s",
        }.merge(@env),
        "terraform", *args,
        chdir: @dir,
      )
      Result.new(stdout, stderr, status)
    end

    def run!(*args)
      result = run(*args)
      unless result.status.success?
        raise "terraform #{args.first} failed:\nSTDOUT:\n#{result.stdout}\nSTDERR:\n#{result.stderr}"
      end
      result
    end
  end

  module SpecHelpers
    # PAT-authenticated account + project, memoized per example,
    # mirroring the API specs' helpers minus the password machinery
    # (PAT auth doesn't need it). The janitor sweeps it all afterward.
    def tf_project
      @tf_project ||= begin
        account = Account.create(email: "tf-#{SecureRandom.hex(4)}@example.com", status_id: 2)
        project = account.create_project_with_default_policy("tf-project")
        pat = ApiKey.create_personal_access_token(account, project:)
        SubjectTag.first(project_id: project.id, name: "Admin").add_subject(pat.id)
        @tf_pat = pat
        @tf_token = "pat-#{pat.ubid}-#{pat.key}"
        project
      end
    end

    def tf_token
      tf_project
      @tf_token
    end

    Fixture = Struct.new(:content)

    # Boilerplate fixtures derive.
    # A resource whose required arguments are all key-shaped (name,
    # project, location) needs no .tf.erb file; curated bodies keep
    # theirs. The address is uniformly ubicloud_<name>.r.
    def derived_fixture(definition)
      spec = TerraformGenerator::Schema.spec_for(definition, :resource)
      required_values = {"name" => "<%= name %>", "project_id" => "<%= project_ubid %>",
                         "location" => "<%= location %>"}
      args = spec["schema"]["attributes"].filter_map do |a|
        type = a.keys.reject { it == "name" }.first
        next unless a[type]["computed_optional_required"] == "required"
        value = required_values[a["name"]] or
          raise "#{definition.name}: required #{a["name"]} needs a curated fixture"
        "  #{a["name"]} = \"#{value}\""
      end
      Fixture.new(<<~TF)
        terraform {
          required_providers {
            ubicloud = { source = "ubicloud/ubicloud" }
          }
        }

        provider "ubicloud" {
          api_endpoint = "<%= endpoint %>"
          api_token    = "<%= token %>"
        }

        resource "ubicloud_#{definition.name}" "r" {
        #{args.join("\n")}
        }
      TF
    end

    # Runner with harness defaults merged under explicit vars; tracked
    # so tmpdirs are removed without per-spec after blocks.
    def tf_runner(fixture, env: {}, **vars)
      defaults = {
        endpoint: TerraformHarness.endpoint,
        token: tf_token,
        project_ubid: tf_project.ubid,
        location: TerraformHarness::LOCATION,
      }
      runner = Runner.new(fixture:, vars: defaults.merge(vars), env:)
      (@tf_runners ||= []) << runner
      runner
    end

    def tf_gate(method: nil, path: nil)
      TerraformHarness.request_gate.register(method:, path:)
    end

    # Background thread for terraform commands that will block at a
    # gate; tracked so a failing example can't leak a running thread
    # (gates are force-released before the join).
    def tf_async(&block)
      thread = Thread.new(&block)
      (@tf_threads ||= []) << thread
      thread
    end

    # --- Control-plane simulation, per resource ---

    # PATs are project-scoped: a terraform-created project must grant
    # the token before reads/refreshes succeed (mirrors real usage).
    def tf_grant_pat!(project)
      tf_project
      SubjectTag.first(project_id: project.id, name: "Admin").add_subject(@tf_pat.id)
    end

    # The routes-spec idiom for lifecycle progression: never run progs,
    # just tick the rows the API derives state from. display_state
    # reads the resource strand label and the initial_provisioning
    # semaphore; "wait" + cleared semaphore reads as "running".
    def make_pg_running!(pg)
      pg.strand.update(label: "wait")
      Semaphore.where(strand_id: pg.strand.id, name: "initial_provisioning").destroy
      pg.reload
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    TerraformHarness.ensure_provider_binary!
    TerraformHarness.start_server!
    TerraformHarness::DatabaseJanitor.snapshot!
  end

  config.after(:suite) do
    TerraformHarness.stop_server!
  end

  config.define_derived_metadata(file_path: %r{\A\./spec/terraform/}) do |metadata|
    # Real HTTP requests from the provider process commit on their own
    # connections; examples must see those writes, and the janitor
    # cleans up after them.
    metadata[:no_db_transaction] = true
  end

  config.after(file_path: %r{\A\./spec/terraform/}) do |example|
    # Soundness sentinels first, while state is live: a ghost writer
    # (second matching mutation slipping a held one-shot gate) is an
    # unsoundness finding regardless of the example's own verdict; on
    # any failure, the mutating-arrival ledger is the forensics.
    gatekeeper = TerraformHarness.request_gate
    violations = gatekeeper&.violations || []
    if example.exception && gatekeeper
      warn "ARRIVALS (#{example.description}):"
      gatekeeper.arrivals.each { warn "  #{it[:m]} #{it[:path]} held=#{it[:held_by_gate]}" }
    end
    # Release any request still parked at a gate (unblocking async
    # terraform runs), join those runs, then reset the world.
    forced = TerraformHarness.request_gate&.clear!
    # A raised join must not skip the sweep (the canary would then
    # block the whole next run); surface it after cleanup instead.
    join_error = nil
    @tf_threads&.each {
      begin
        it.join
      rescue
        join_error ||= $!
      end
    }
    @tf_runners&.each(&:cleanup)
    TerraformHarness::DatabaseJanitor.sweep!
    raise join_error if join_error
    unless violations.empty?
      raise "GATE SOUNDNESS VIOLATION - ghost writer past a held one-shot gate:\n" +
        violations.map { "  #{it[:m]} #{it[:path]} while held: #{it[:held_gate]}" }.join("\n")
    end
    warn "note: force-released #{forced} held gate(s) in teardown" if forced.to_i > 0 && !example.exception
  end

  config.include TerraformHarness::SpecHelpers
end
