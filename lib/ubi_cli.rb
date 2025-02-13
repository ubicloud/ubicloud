# frozen_string_literal: true

class UbiCli
  def self.process(argv, env)
    UbiRodish.process(argv, context: new(env))
  rescue Rodish::CommandExit => e
    if e.failure?
      status = 400
      message = e.message_with_usage
    else
      status = 200
      message = e.message
    end

    [status, {"content-type" => "text/plain", "content-length" => message.bytesize.to_s}, [message]]
  end

  def self.base(cmd, &block)
    UbiRodish.on(cmd) do
      # :nocov:
      unless Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
        autoload_subcommand_dir("cli-commands/#{cmd}")
        autoload_post_subcommand_dir("cli-commands/#{cmd}/post")
      end
      # :nocov:

      args(2...)

      instance_exec(&block)

      run do |(ref, *argv), opts, command|
        @location, @name, extra = ref.split("/", 3)
        raise Rodish::CommandFailure, "invalid #{cmd} reference, should be in location/(#{cmd}-name|_#{cmd}-ubid) format" if extra
        command.run(self, opts, argv)
      end
    end
  end

  def self.list(cmd, label, fields, fragment: cmd)
    fields.freeze.each(&:freeze)
    key = :"#{cmd}_list"

    UbiRodish.on(cmd, "list") do
      options("ubi #{cmd} list [options]", key:) do
        on("-f", "--fields=fields", "show specific fields (default: #{fields.join(",")})")
        on("-l", "--location=location", "only show #{label} in given location")
        on("-N", "--no-headers", "do not show headers")
      end

      run do |opts|
        opts = opts[key]
        path = if opts && (location = opts[:location])
          if LocationNameConverter.to_internal_name(location)
            "location/#{location}/#{fragment}"
          else
            raise Rodish::CommandFailure, "invalid location provided in #{cmd} list -l option"
          end
        else
          fragment
        end

        get(project_path(path)) do |data|
          keys = fields
          headers = true

          if opts
            keys = check_fields(opts[:fields], fields, "#{cmd} list -f option")
            headers = false if opts[:"no-headers"] == false
          end

          format_rows(keys, data["items"], headers:)
        end
      end
    end
  end

  def self.destroy(cmd, label, fragment: cmd)
    UbiRodish.on(cmd).run_on("destroy") do
      options("ubi #{cmd} location/(#{cmd}-name|_#{cmd}-ubid) destroy [options]", key: :destroy) do
        on("-f", "--force", "do not require confirmation")
      end

      run do |opts|
        if opts.dig(:destroy, :force) || opts[:confirm] == @name
          delete(project_path("location/#{@location}/#{fragment}/#{@name}")) do |_, res|
            ["#{label}, if it exists, is now scheduled for destruction"]
          end
        elsif opts[:confirm]
          invalid_confirmation <<~END

            Confirmation of #{label} name not successful.
          END
        else
          require_confirmation("Confirmation", <<~END)
            Destroying this #{label} is not recoverable.
            Enter the following to confirm destruction of the #{label}: #{@name}
          END
        end
      end
    end
  end

  def self.pg_cmd(cmd)
    UbiRodish.on("pg").run_on(cmd) do
      skip_option_parsing("ubi pg location-name/(pg-name|_pg-ubid) #{cmd} [#{cmd}-opts]")

      args(0...)

      run do |argv, opts|
        get(project_path("location/#{@location}/postgres/#{@name}")) do |data, res|
          conn_string = URI(data["connection_string"])
          if (opts = opts[:pg_psql])
            if (user = opts[:username])
              conn_string.user = user
              conn_string.password = nil
            end

            if (database = opts[:dbname])
              conn_string.path = "/#{database}"
            end
          end

          argv = [cmd, *argv, "--", conn_string]
          argv = yield(argv) if block_given?

          execute_argv(argv, res)
        end
      end
    end
  end

  def initialize(env)
    @env = env
  end

  def project_ubid
    @project_ubid ||= @env["clover.project_ubid"]
  end

  def handle_ssh(opts)
    get(project_path("location/#{@location}/vm/#{@name}")) do |data, res|
      if (opts = opts[:vm_ssh])
        user = opts[:user]
        if opts[:ip4]
          address = data["ip4"] || false
        elsif opts[:ip6]
          address = data["ip6"]
        end
      end

      if address.nil?
        address = if ipv6_request?
          data["ip6"] || data["ip4"]
        else
          data["ip4"] || data["ip6"]
        end
      end

      if address
        user ||= data["unix_user"]
        execute_argv(yield(user:, address:), res)
      else
        res[0] = 400
        ["No valid IPv4 address for requested VM"]
      end
    end
  end

  def execute_argv(args, res)
    res[1]["ubi-command-execute"] = args.shift
    [args.join("\0")]
  end

  def check_fields(given_fields, allowed_fields, option_name)
    if given_fields
      keys = given_fields.split(",")

      if keys.empty?
        raise Rodish::CommandFailure, "no fields given in #{option_name}"
      end
      unless keys.size == keys.uniq.size
        raise Rodish::CommandFailure, "duplicate field(s) in #{option_name}"
      end

      invalid_keys = keys - allowed_fields
      unless invalid_keys.empty?
        raise Rodish::CommandFailure, "invalid field(s) given in #{option_name}: #{invalid_keys.join(",")}"
      end

      keys
    else
      allowed_fields
    end
  end

  def delete(path, params = {}, &block)
    _req(_req_env("DELETE", path, params), &block)
  end

  def post(path, params = {}, &block)
    _req(_req_env("POST", path, params), &block)
  end

  def get(path, &block)
    _req(_req_env("GET", path, nil), &block)
  end

  def project_path(rest)
    "/project/#{project_ubid}/#{rest}"
  end

  def format_rows(keys, rows, headers: false, col_sep: "  ")
    results = []

    sizes = Hash.new(0)
    string_keys = keys.map(&:to_s)
    string_keys.each do |key|
      sizes[key] = headers ? key.size : 0
    end
    rows = rows.map do |row|
      row.transform_values(&:to_s)
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
      string_keys.each do |key|
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

  private

  def invalid_confirmation(message)
    response(message, status: 400)
  end

  def require_confirmation(prompt, confirmation)
    response(confirmation, headers: {"ubi-confirm" => prompt})
  end

  def response(body, status: 200, headers: {})
    if body.is_a?(Array)
      headers["content-length"] = body.sum(&:bytesize).to_s
    else
      headers["content-length"] = body.bytesize.to_s
      body = [body]
    end

    headers["content-type"] = "text/plain"
    [status, headers, body]
  end

  def _req_env(method, path, params)
    env = @env.merge(
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.request.form_input" => nil,
      "rack.request.form_hash" => nil
    )
    params &&= params.to_json.force_encoding(Encoding::BINARY)
    env["rack.input"] = StringIO.new(params || "".b)
    env.delete("roda.json_params")
    env
  end

  def _req(env)
    res = _submit_req(env)

    case res[0]
    when 200
      # Temporary nocov until at least one action pushed into routes
      # :nocov:
      if res[1]["content-type"] == "application/json"
        # :nocov:
        body = +""
        res[2].each { body << _1 }
        res[2] = yield(JSON.parse(body), res)
        res[1]["content-length"] = res[2].sum(&:bytesize).to_s
      end
    when 204
      res[0] = 200
      res[2] = yield(nil, res)
      res[1]["content-length"] = res[2].sum(&:bytesize).to_s
    else
      body = +""
      res[2].each { body << _1 }
      error_message = "Error: unexpected response status: #{res[0]}"
      # Temporary nocov until at least one action pushed into routes
      # :nocov:
      if (res[1]["content-type"] == "application/json") && (parsed_body = JSON.parse(body)) && (error = parsed_body.dig("error", "message"))
        # :nocov:
        error_message << "\nDetails: #{error}"
        if (details = parsed_body.dig("error", "details"))
          details.each do |k, v|
            error_message << "\n  " << k.to_s << ": " << v.to_s
          end
        end
      end
      res[2] = [error_message]
      res[1]["content-length"] = res[2][0].bytesize.to_s
    end

    res[1]["content-type"] = "text/plain"
    res
  end

  def _submit_req(env)
    Clover.call(env)
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

    prepend(Module.new do
      def _submit_req(env)
        DB.allow_queries do
          super
        end
      end
    end)
  end
  # :nocov:
end
