# frozen_string_literal: true

require "rodish"
require_relative "../sdk/ruby/lib/ubicloud"

class UbiCli
  force_autoload = Config.production? || ENV["FORCE_AUTOLOAD"] == "1"

  SDK_METHODS = {
    "fw" => "firewall",
    "ak" => "inference_api_key",
    "kc" => "kubernetes_cluster",
    "lb" => "load_balancer",
    "pg" => "postgres",
    "ps" => "private_subnet",
    "vm" => "vm"
  }.freeze

  CAPITALIZED_LABELS = {
    "fw" => "Firewall",
    "ak" => "Inference API key",
    "kc" => "Kubernetes cluster",
    "lb" => "Load balancer",
    "pg" => "PostgreSQL database",
    "ps" => "Private subnet",
    "vm" => "Virtual machine"
  }.freeze

  LOWERCASE_LABELS = CAPITALIZED_LABELS.transform_values(&:downcase)
  LOWERCASE_LABELS["pg"] = CAPITALIZED_LABELS["pg"]
  LOWERCASE_LABELS["kc"] = CAPITALIZED_LABELS["kc"]
  LOWERCASE_LABELS["ak"] = "inference API key"
  LOWERCASE_LABELS.freeze

  OBJECT_INFO_REGEXP = /((fw|kc|1b|pg|ps|vm)[a-z0-9]{24})/
  UBI_VERSION_REGEXP = /\A\d{1,4}\.\d{1,4}\.\d{1,4}\z/

  Rodish.processor(self)

  plugin :help_examples
  plugin :help_option_values
  plugin :help_order, default_help_order: [:desc, :banner, :examples, :commands, :options, :option_values]
  plugin :post_commands
  plugin :skip_option_parsing

  on do
    desc "CLI to interact with Ubicloud"

    options("ubi command [command-options] ...") do
      on("--confirm=confirmation", "confirmation value")
    end

    help_order(:desc, :banner, :examples, :commands)

    help_example "ubi vm list    # List virtual machines"
    help_example "ubi help vm    # Get help for vm subcommand"

    # :nocov:
    autoload_subcommand_dir("cli-commands") unless force_autoload
    # :nocov:
  end

  def self.process(argv, env)
    super
  rescue Ubicloud::Error => e
    status = e.code
    message = "! Unexpected response status: #{e.code}"
    parsed_body = e.params
    message << "\nDetails: #{parsed_body.dig("error", "message")}"
    if (details = parsed_body.dig("error", "details"))
      details.each do |k, v|
        message << "\n  " << k.to_s << ": " << v.to_s
      end
    end
    message += "\n"
    [status, {"content-type" => "text/plain", "content-length" => message.bytesize.to_s}, [message]]
  rescue Rodish::CommandFailure => e
    status = 400
    message = e.message_with_usage.dup
    message[0] = "! #{message[0].capitalize}"
    message += "\n" unless message.end_with?("\n")

    [status, {"content-type" => "text/plain", "content-length" => message.bytesize.to_s}, [message]]
  end

  def self.base(cmd, &block)
    on(cmd) do
      label = LOWERCASE_LABELS[cmd]

      desc "Manage #{label}s"

      # :nocov:
      unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
        autoload_subcommand_dir("cli-commands/#{cmd}")
        autoload_post_subcommand_dir("cli-commands/#{cmd}/post")
      end
      # :nocov:

      args(2...)

      instance_exec(&block)

      run do |(ref, *argv), opts, command|
        @sdk_method = SDK_METHODS[cmd]

        if command.post_subcommand(ref)
          # support swapped reference and post command arguments
          argv.insert(1, ref)
          ref = argv.shift
        end

        @location, @name, extra = ref.split("/", 3)

        if !@name && OBJECT_INFO_REGEXP.match?(@location)
          unless (object = sdk[@location])
            raise Rodish::CommandFailure.new("no #{label} with id #{@location} exists", command)
          end

          @name = @location
          @location = object.location
        end

        if extra || !@name
          raise Rodish::CommandFailure.new("invalid #{cmd} reference (#{ref.inspect}), should be in location/#{cmd}-name or #{cmd}-id format", command)
        end

        command.run(self, opts, argv)
      end
    end
  end

  def self.list(cmd, fields)
    fields.freeze.each(&:freeze)
    key = :"#{cmd}_list"
    sdk_method = SDK_METHODS[cmd]

    on(cmd, "list") do
      desc "List #{LOWERCASE_LABELS[cmd]}s"

      options("ubi #{cmd} list [options]", key:) do
        on("-f", "--fields=fields", "show specific fields (comma separated)")
        on("-l", "--location=location", "only show #{LOWERCASE_LABELS[cmd]}s in given location")
        on("-N", "--no-headers", "do not show headers")
      end
      help_option_values("Fields:", fields)

      run do |opts, command|
        opts = opts[key]
        if (location = opts[:location])
          unless location.match(Validation::ALLOWED_NAME_PATTERN)
            raise Rodish::CommandFailure.new("invalid location provided in #{cmd} list -l option", command)
          end
        end

        items = sdk.send(sdk_method).list(location:)
        keys = underscore_keys(check_fields(opts[:fields], fields, "#{cmd} list -f option", command))
        response(format_rows(keys, items, headers: opts[:"no-headers"] != false))
      end
    end
  end

  def self.destroy(cmd)
    on(cmd).run_on("destroy") do
      desc "Destroy a #{LOWERCASE_LABELS[cmd]}"

      options("ubi #{cmd} (location/#{cmd}-name | #{cmd}-id) destroy [options]", key: :destroy) do
        on("-f", "--force", "do not require confirmation")
      end

      run do |opts|
        if opts.dig(:destroy, :force) || opts[:confirm] == @name
          sdk_object.destroy
          response("#{CAPITALIZED_LABELS[cmd]}, if it exists, is now scheduled for destruction")
        elsif opts[:confirm]
          invalid_confirmation <<~END
            ! Confirmation of #{LOWERCASE_LABELS[cmd]} name not successful.
          END
        else
          require_confirmation("Confirmation", <<~END)
            Destroying this #{LOWERCASE_LABELS[cmd]} is not recoverable.
            Enter the following to confirm destruction of the #{LOWERCASE_LABELS[cmd]}: #{@name}
          END
        end
      end
    end
  end

  MIN_PGPASSWORD_VERSION = Gem::Version.new("1.1.0")
  def self.pg_cmd(cmd, desc)
    on("pg").run_on(cmd) do
      desc(desc)

      skip_option_parsing("ubi pg (location/pg-name | pg-id) [options] #{cmd} [#{cmd}-options]")

      args(0...)

      run do |argv, opts|
        pg = sdk_object.info
        conn_string = URI(pg.connection_string)
        opts = opts[:pg_psql]
        if (user = opts[:username])
          conn_string.user = user
          conn_string.password = nil
        elsif comparable_client_version >= MIN_PGPASSWORD_VERSION
          pgpassword = conn_string.password
          conn_string.password = nil
          headers = {"ubi-pgpassword" => pgpassword}
        end

        if (database = opts[:dbname])
          conn_string.path = "/#{database}"
        end

        argv = [cmd, *argv, "--", conn_string]
        argv = yield(argv) if block_given?
        execute_argv(argv, **headers)
      end
    end
  end

  def initialize(env)
    @env = env
  end

  private

  def project_ubid
    @project_ubid ||= @env["clover.project_ubid"]
  end

  def handle_ssh(opts)
    vm = sdk_object.info
    opts = opts[:vm_ssh]
    user = opts[:user]
    if opts[:ip4]
      address = vm.ip4 || false
    elsif opts[:ip6]
      address = vm.ip6
    end

    if address.nil?
      address = if ipv6_request?
        vm.ip6 || vm.ip4
      else
        vm.ip4 || vm.ip6
      end
    end

    if address
      user ||= vm.unix_user
      execute_argv(yield(user:, address:))
    else
      response("! No valid IPv4 address for requested VM", status: 400)
    end
  end

  def need_integer_arg(v, arg_name, cmd)
    raise Rodish::CommandFailure.new("invalid #{arg_name} argument: #{v.inspect}", cmd) unless (i = Integer(v, exception: false))
    i
  end

  def execute_argv(argv, **headers)
    headers["ubi-command-execute"] = argv.shift
    response(argv.join("\0"), headers:)
  end

  def check_fields(given_fields, allowed_fields, option_name, cmd)
    if given_fields
      keys = given_fields.split(",")

      if keys.empty?
        raise Rodish::CommandFailure.new("no fields given in #{option_name}", cmd)
      end
      unless keys.size == keys.uniq.size
        raise Rodish::CommandFailure.new("duplicate field(s) in #{option_name}", cmd)
      end

      invalid_keys = keys - allowed_fields
      unless invalid_keys.empty?
        raise Rodish::CommandFailure.new("invalid field(s) given in #{option_name}: #{invalid_keys.join(",")}", cmd)
      end

      keys
    else
      allowed_fields
    end
  end

  def format_rows(keys, rows, headers: false, col_sep: "  ")
    results = []

    sizes = Hash.new(0)
    keys.each do |key|
      sizes[key] = headers ? key.size : 0
    end
    rows = rows.map do |row|
      row.to_h.transform_values(&:to_s)
    end
    rows.each do |row|
      keys.each do |key|
        size = row[key].size
        sizes[key] = size if size > sizes[key]
      end
    end
    sizes.transform_values! do |size|
      "%-#{size}s"
    end

    if headers
      sep = false
      keys.each do |key|
        if sep
          results << col_sep
        else
          sep = true
        end
        results << (sizes[key] % key)
      end
      results << "\n"
    end

    rows.each do |row|
      sep = false
      keys.each do |key|
        if sep
          results << col_sep
        else
          sep = true
        end
        results << (sizes[key] % row[key])
      end
      results << "\n"
    end

    results
  end

  def ipv6_request?
    @env["puma.socket"]&.local_address&.ipv6?
  end

  def underscore_keys(keys)
    if keys.is_a?(Hash)
      keys.transform_keys { it.to_s.tr("-", "_").to_sym }
    else # when Array
      keys.map { it.tr("-", "_").to_sym }
    end
  end

  def client_version
    @client_version ||= begin
      version_header = @env["HTTP_X_UBI_VERSION"]
      UBI_VERSION_REGEXP.match?(version_header) ? version_header : "unknown"
    end
  end

  def comparable_client_version
    Gem::Version.new(/\A(\d+)\.(\d+)\.(\d+)\z/.match?(client_version) ? client_version : "0.0.0")
  end

  def invalid_confirmation(message)
    response(message, status: 400)
  end

  def require_confirmation(prompt, confirmation)
    response(confirmation, headers: {"ubi-confirm" => prompt})
  end

  def response(body, status: 200, headers: {})
    body = [body] unless body.is_a?(Array)
    finalize_response([status, headers, body])
  end

  def sdk
    @sdk ||= Ubicloud.new(:rack, app: Clover, env: @env, project_id: project_ubid)
  end

  def sdk_object
    sdk.send(@sdk_method).new("#{@location}/#{@name}")
  end

  def finalize_response(res)
    headers = res[1]
    body = res[2]
    if !headers["ubi-command-execute"] && !headers["ubi-confirm"] && (body.empty? || !body[-1].end_with?("\n"))
      body << "\n"
    end
    headers["content-length"] = body.sum(&:bytesize).to_s
    headers["content-type"] = "text/plain"
    res
  end

  def check_no_slash(string, error_message, cmd)
    raise Rodish::CommandFailure.new(error_message, cmd) if string.include?("/")
  end

  # :nocov:
  if Config.test? && ENV["CLOVER_FREEZE"] == "1"
    singleton_class.prepend(Module.new do
      def process(argv, env)
        DB.block_queries do
          super
        end
      end
    end)

    require_relative "../sdk/ruby/lib/ubicloud/adapter"
    require_relative "../sdk/ruby/lib/ubicloud/adapter/rack"
    Ubicloud::Adapter::Rack.prepend(Module.new do
      def call(...)
        DB.allow_queries do
          super
        end
      end
    end)
  end
  # :nocov:

  Unreloader.record_dependency("lib/rodish.rb", __FILE__)
  Unreloader.record_dependency(__FILE__, "cli-commands")
  if force_autoload
    Unreloader.require("cli-commands") {}
  # :nocov:
  else
    Unreloader.autoload("cli-commands") {}
  end
  # :nocov:
end
