# frozen_string_literal: true

class Clover < Roda
  API_MEDIA_TYPE = "application/vnd.ubicloud+json"

  API_VERSIONS = (1..OPENAPI.raw_schema.dig("info", "x-api-version")).to_a.freeze

  # A deprecated operation (name is nil) or request body property, as
  # described by its x-deprecated mark in the spec.
  Deprecation = Data.define(:operation, :name, :use, :since, :removed_in) do
    def self.from(operation, name, x)
      new(operation, name, x.fetch("use", []).freeze, x.fetch("since"), x.fetch("removed-in"))
    end

    def used?(body) = !name || body.key?(name)

    def key = [operation, name].compact.join(".")

    def subject = name || operation
  end

  # The deprecations of each operation, by operationId.
  DEPRECATIONS = OPENAPI.paths.path.each_value.flat_map { |item| [item.get, item.post, item.patch, item.put, item.delete].compact }.to_h { |op|
    id = op.operation_id
    properties = op.request_body ? op.request_body.content["application/json"].schema.properties || {} : {}
    marked = properties.filter_map do |name, schema|
      Deprecation.from(id, name, schema.raw_schema["x-deprecated"]) if schema.raw_schema["x-deprecated"]
    end
    marked.unshift(Deprecation.from(id, nil, op.raw_schema["x-deprecated"])) if op.raw_schema["x-deprecated"]
    [id, marked.freeze]
  }.reject { |_, marked| marked.empty? }.freeze

  # As in pliny, a request selects a version with a parameter on our vendor
  # media type: "Accept: application/vnd.ubicloud+json; version=2".
  def api_version
    @api_version ||= if (range = env["HTTP_ACCEPT"]&.split(",")&.find { it.match?(%r{\A\s*application/vnd\.ubicloud\+json\s*(;|\z)}i) })
      unless (version = range[/;\s*version="?([1-9]\d{0,3})"?\s*(;|\z)/i, 1]&.to_i)
        fail CloverError.new(400, "InvalidRequest",
          "Accept names #{API_MEDIA_TYPE} without a valid version; send #{API_MEDIA_TYPE}; version=#{API_VERSIONS.last}")
      end
      unless API_VERSIONS.include?(version)
        fail CloverError.new(406, "NotAcceptable", "API version #{version} does not exist; the versions are #{API_VERSIONS.join(", ")}")
      end
      version
    else
      1
    end
  end

  # Committee accepts every deprecated name, since the spec still lists them
  # all. Refuse those that the request's version removed, and warn of the rest.
  def check_deprecations(operation)
    return unless (deprecations = DEPRECATIONS[operation.request_operation.operation_object.operation_id])
    return if (used = deprecations.select { it.used?(request.POST) }).empty?

    refuse_removed(used)
    @deprecations_used = used
    brownout(used, operation.path_params["project_id"])
  end

  def refuse_removed(used)
    if (gone = used.find { !it.name && it.removed_in <= api_version })
      fail CloverError.new(410, "Gone", removal_message(gone))
    end
    return if (removed = used.select { it.removed_in <= api_version }).empty?

    details = removed.to_h { [it.name, removal_message(it)] }
    fail CloverError.new(400, "InvalidRequest", details.values.join("; "), details)
  end

  def brownout(used, project_id)
    share = used.map { Config.api_deprecation_brownout.fetch(it.removed_in, 0.0) }.max
    refused = rand < share
    Clog.emit("deprecated api use", {deprecated_api_use: {
      project_id:, version: api_version, keys: used.map(&:key), refused:, user_agent: env["HTTP_USER_AGENT"].to_s[0, 200],
    }})
    return unless refused

    message = "#{used.map { deprecation_message(it) }.join("; ")}. Requests that use a deprecated name will stop working; " \
      "to warn of that, #{format("%g", share * 100)}% of them are refused now, including this one."
    fail CloverError.new(400, "Deprecated", message, used.select(&:name).to_h { [it.name, deprecation_message(it)] })
  end

  # Called from the after hook, because the error handler resets the response
  # and brownout refusals need these headers too.
  def add_deprecation_headers(headers)
    headers["deprecation"] = "@#{@deprecations_used.map { it.since.strftime("%s").to_i }.min}"
    headers["warning"] = @deprecations_used.map { "299 - #{deprecation_message(it).dump}" }.join(", ")
  end

  def deprecation_message(d) = "#{d.subject} is deprecated: #{replacement(d)}"

  def removal_message(d) = "#{d.subject} was removed in API version #{d.removed_in}: #{replacement(d)}"

  def replacement(d) = d.use.empty? ? "omit it" : "use #{d.use.join(" and ")} instead"
end
