# frozen_string_literal: true

require "date"

# Conventions that openapi.yml should keep. Each norm is a method named norm_<name>, which
# lists its violations as "<name>: <place>: <what to do>". A place is named after the schema
# that defines it, such as Vm.name, createVM.enable_ip4 for an inline request body,
# responses/FirewallDetailed/allOf/1.private_subnets for an allOf member's property, or
# parameters/location.
#
# The terraform generator, which must not load clover, is to check its types with this file, so
# the file uses only the standard library.
class OpenapiNorms
  METHODS = %w[get put post patch delete].freeze

  # request and response map each top-level property name in the operation's request body and
  # success response to [schema, place]. response is nil when no success response has a JSON body.
  Operation = Data.define(:id, :op, :parameters, :request, :required, :response)

  def initialize(doc)
    @doc = doc
    @operations = doc["paths"].flat_map do |_, item|
      shared = item.fetch("parameters", [])
      item.slice(*METHODS).map { |_, op| operation(op, shared + op.fetch("parameters", [])) }
    end
  end

  def violations
    self.class.private_instance_methods(false).grep(/\Anorm_/).sort.flat_map { send(it) }.uniq
  end

  private

  def norm_echo
    exchanges.flat_map do |o|
      o.request.filter_map do |name, (s, at)|
        next if o.response.key?(name) || s["writeOnly"] || s["deprecated"]
        "echo: #{at}: echo it in the response, or mark it writeOnly"
      end
    end
  end

  def norm_direction
    carried = {}
    answers.each do |o|
      o.response.each { |name, (s, at)| carried[at] = [s, carried.dig(at, 1) || o.request.key?(name)] }
    end
    carried.filter_map do |at, (s, sent)|
      "direction: #{at}: mark it readOnly, or accept it in a request" unless sent || s["readOnly"] || s["deprecated"]
    end
  end

  def norm_echo_agreement
    exchanges.flat_map do |o|
      o.request.filter_map do |name, (s, at)|
        next unless (echo = o.response[name]) && !accepts?(resolve(s), resolve(echo[0]))
        "echo_agreement: #{at}: accept every value #{echo[1]} may hold"
      end
    end
  end

  def norm_described
    places = body_properties + parameters
    places.filter_map do |s, at|
      "described: #{at}: describe it" unless resolve(s)["description"] || s["description"]
    end
  end

  def norm_immutable_readonly
    body_properties.filter_map do |s, at|
      "immutable_readonly: #{at}: mark it readOnly, or drop x-immutable" if s["x-immutable"] && !s["readOnly"]
    end
  end

  def norm_lifecycle_enum
    answers.flat_map do |o|
      marked = o.response.values.select { |s, _| s.key?("x-lifecycle") }
      wrong = marked.filter_map do |s, at|
        "lifecycle_enum: #{at}: mark it readOnly, and list only values of its enum under pending and failed" unless lifecycle?(s)
      end
      wrong << "lifecycle_enum: #{marked.map(&:last).join(", ")}: mark only one property of a response with x-lifecycle" if marked.size > 1
      wrong
    end
  end

  def lifecycle?(s)
    x = s["x-lifecycle"]
    return false unless s["readOnly"] && x.is_a?(Hash) && (x.keys - %w[pending failed]).empty?
    x.values.all? { it.is_a?(Array) && (it - s.fetch("enum", [])).empty? }
  end

  # A parameter may give named examples instead of an example.
  def norm_examples
    needed = parameters.select { it[0]["in"] == "path" } +
      @operations.flat_map { |o| [*o.request.values_at(*o.required), *o.response&.values_at("id")].compact }
    needed.filter_map do |s, at|
      next if s.key?("examples") || [s, s.fetch("schema", {}), resolve(s)].any? { it.key?("example") }
      "examples: #{at}: give it an example"
    end
  end

  # An operation's use names other operations, a request property's use names its siblings or any
  # operation, and a response property's use names its siblings. Only a request property may be
  # renamed, to a sibling that is not deprecated and has the same type.
  def norm_deprecation
    ids = @operations.map(&:id)
    @operations.filter_map { deprecation(it.op, it.id, ids - [it.id]) } +
      @operations.flat_map do |o|
        o.request.filter_map do |name, (s, at)|
          siblings = o.request.except(name).transform_values(&:first)
          deprecation(s, at, siblings.keys + ids, siblings:, required: o.required.include?(name))
        end
      end +
      answers.flat_map do |o|
        o.response.filter_map { |name, (s, at)| deprecation(s, at, o.response.keys - [name], response: true) }
      end
  end

  def deprecation(node, at, names, siblings: {}, required: false, response: false)
    return unless node["deprecated"] || node["x-deprecated"]
    x = node["x-deprecated"]
    return "deprecation: #{at}: give it both deprecated: true and x-deprecated" unless node["deprecated"] && x.is_a?(Hash)
    use = x.fetch("use", [])
    version = x["removed-in"]
    problems = [
      ("give x-deprecated a since date" unless x["since"].is_a?(Date)),
      ("make use a list of names that exist" unless use.is_a?(Array) && (use - names).empty?),
      ("give x-deprecated removed-in, an API version above 1" if !response && !(version.is_a?(Integer) && version > 1)),
      ("drop removed-in, since responses are the same in every version" if response && x.key?("removed-in")),
      ("make renamed-to name a sibling request property of the same type" unless renamed?(x["renamed-to"], node, siblings)),
      ("take it out of required, since a client may send its replacement instead" if required),
    ].compact
    "deprecation: #{at}: #{problems.join("; ")}" if problems.any?
  end

  def renamed?(name, node, siblings)
    return true unless name
    (to = siblings[name]) && !to["deprecated"] && resolve(to)["type"] == resolve(node)["type"]
  end

  def operation(op, parameters)
    id = op["operationId"]
    body = op.dig("requestBody", "content", "application/json", "schema")
    code, success = op["responses"].find { |c, _| c.start_with?("2") }
    home = success&.key?("$ref") ? "responses/#{ref_name(success)}" : "#{id} #{code}"
    schema = success && resolve(success).dig("content", "application/json", "schema")
    Operation.new(id:, op:, parameters:,
      request: body ? properties(body, id) : {},
      required: body ? resolve(body).fetch("required", []) : [],
      response: schema && properties(schema, home))
  end

  def answers = @operations.select(&:response)

  def exchanges = answers.select { it.request.any? }

  def body_properties = @operations.flat_map { [*it.request.values, *it.response&.values] }

  def parameters
    found = @operations.flat_map do |o|
      o.parameters.map { [resolve(it), it.key?("$ref") ? "parameters/#{ref_name(it)}" : "#{o.id} param #{it["name"]}"] }
    end
    found.uniq { it[1] }
  end

  # Whether a request schema accepts every value that a response schema may hold.
  def accepts?(req, resp)
    if (members = resp["anyOf"] || resp["oneOf"])
      return members.all? { accepts?(req, resolve(it)) }
    end
    if (members = req["anyOf"] || req["oneOf"])
      return members.any? { accepts?(resolve(it), resp) }
    end
    req["type"] == resp["type"] && [nil, resp["format"]].include?(req["format"]) &&
      (!req["enum"] || (resp.fetch("enum", [nil]) - req["enum"]).empty?) &&
      %w[items additionalProperties].all? do |k|
        !(req[k].is_a?(Hash) && resp[k].is_a?(Hash)) || accepts?(resolve(req[k]), resolve(resp[k]))
      end
  end

  def resolve(node)
    node = @doc.dig(*node["$ref"].delete_prefix("#/").split("/")) while node.key?("$ref")
    node
  end

  def ref_name(node) = node["$ref"].split("/").last

  # A schema's top-level properties, following $ref and the members of allOf, anyOf and oneOf.
  def properties(schema, at)
    return properties(resolve(schema), ref_name(schema)) if schema.key?("$ref")
    members = %w[allOf anyOf oneOf].flat_map do |k|
      schema.fetch(k, []).each_with_index.map { |m, i| properties(m, "#{at}/#{k}/#{i}") }
    end
    members.reduce({}, :merge).merge(schema.fetch("properties", {}).to_h { |name, s| [name, [s, "#{at}.#{name}"]] })
  end
end
