# frozen_string_literal: true

class UbiCli
  def self.process(argv, env)
    UbiRodish.process(argv, context: new(env))
  rescue Rodish::CommandExit => e
    [e.failure? ? 400 : 200, {"content-type" => "text/plain"}, [e.message]]
  end

  def initialize(env)
    @env = env
  end

  def project_ubid
    @project_ubid ||= @env["clover.project_ubid"]
  end

  def handle_ssh(opts)
    get(project_path("location/#{@location}/vm/#{@vm_name}")) do |data, res|
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
        args = yield(user:, address:)
        res[1]["ubi-command-execute"] = args.shift
        [args.join("\0")]
      else
        res[0] = 400
        ["No valid IPv4 address for requested VM"]
      end
    end
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
            error_message << "\n  " << k << ": " << v
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
