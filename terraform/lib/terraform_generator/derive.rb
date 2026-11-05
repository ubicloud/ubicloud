# frozen_string_literal: true

require "did_you_mean"

# Derive gives the Type of one definition. Each derivation rule is a method
# of the same name, and a statement's provenance names the rules that
# shaped it, so grep finds the rule behind any generated line. A spec that
# breaks an invariant raises SpecError, naming the spec location and the fix.
class TerraformGenerator::Derive
  include TerraformGenerator

  # Rule clauses that each exist for a single type; special_cases counts them.
  CLAUSES = %i[item_post_verb merge_subroute name_carrier union_collapse].freeze

  SCALARS = {"integer" => :i64, "boolean" => :boolean}.freeze
  FORMATS = {"date-time" => :timestamp, "cidr" => Call.new(:string_of, ["cidr"]), "port-range" => Call.new(:string_of, ["port-range"])}.freeze
  DEFAULTS = {String => :default_string, Integer => :default_int, TrueClass => :default_bool, FalseClass => :default_bool}.freeze
  LIFECYCLE = {"pending" => Pending, "failed" => Failed}.freeze

  # A schema the derivation read, and its place in the spec as provenance
  # names it: Response.property, operationId.property or {param}.
  Prop = Data.define(:schema, :at)

  # The rule that makes an attribute of a path parameter, the parameter's
  # name, and the schema the attribute's checks come from.
  Key = Data.define(:rule, :param, :check)

  # An attribute's key, request property and response property, any of which may be nil.
  Source = Data.define(:name, :key, :req, :resp)

  # A candidate verb, which is a verb unless a rule has set it aside.
  Candidate = Data.define(:path, :method, :id, :body, :why, :verb)

  def initialize(api, name, facts)
    @api = api
    @name = name.to_s
    @facts = facts
    unknown = facts.keys - Definitions::KEYS
    refuse "definitions #{@name}", "unknown key #{unknown.join(", ")}; the keys are #{Definitions::KEYS.join(", ")}" if unknown.any?
    @item = one_item_path
    @create_path, @create = create_op
    @get = api.paths[@item.path]["get"]
    crud_ops
    @response = response_props(@get)
    @keys = keys
    @create_body = @create ? body(@create) : {}
    @required = @create_body.keys & Array(@create && content(@create["requestBody"])&.dig("required"))
    @verbs = verb_owner(verb_order(@create ? verb_candidates : []))
    bodies = @verbs.select(&:verb).map(&:body)
    @owned = bodies.flat_map(&:keys)
    # An input's request property is the create body's, else the first verb's.
    @request = [@create_body, *bodies].reverse.reduce(:merge)
  end

  def type
    attrs = [identity, *attribute_set.map { attribute(it) }].sort_by(&:name)
    response_direction
    input_echo
    body = body_example
    values = example(body)
    examples(values)
    inputs = attrs.select { it.flags.include?(:required) || body.key?(it.name) }
    statements = [create, kinds, *lifecycle, *attrs, *@verbs.map { statement(it) }].compact
    item = in_attributes(@item.path, scope? ? identity_name : "id")
    at = response_name(@get)
    doc = success(@get)["description"] || described(at)
    Type.new(name: @name, item:, doc:, statements:, examples: values, example_inputs: inputs.map(&:name), references: references(inputs), why: [[:type_name, @get["operationId"]], [:doc, at]])
  end

  private

  def refuse(at, message) = raise(SpecError, "#{at}: #{message}")

  def one_item_path
    @api.items.fetch(@name) do
      near = DidYouMean::SpellChecker.new(dictionary: @api.items.keys).correct(@name)
      refuse "definitions #{@name}", "no item path derives this name#{"; the nearest are #{near.join(", ")}" if near.any?}"
    end
  end

  # The scope's parameters are provider configuration, never attributes: a
  # token works in one scope, so an attribute would only repeat it.
  def scope = @api.scope.scan(/\{(\w+)\}/).flatten

  def scope? = @item.path == @api.scope

  def identity_name = @item.params.last["name"]

  # A type is named when its identity parameter accepts a name, which is
  # then its create's idempotency key. Every type has a datasource, since
  # it has an item GET. Besides the keys, the datasource takes id, or id
  # or name when the type is named; the scope's takes nothing.
  def kinds = Datasource.new(scope? ? [] : ["id", *("name" if named?)], [[:kinds, "{#{identity_name}}"]])

  def named? = @item.params.last.dig("schema", "$ref") == "#/components/schemas/Reference"

  # The attributes that path parameters fill: those between the scope and
  # the identity, and the name when the create is the POST on the item.
  def keys
    keys = @item.params[scope.size...-1].to_h { (it["name"] == "location") ? location(it) : parent_key(it) }
    return keys unless @create_path == @item.path
    keys.merge("name" => Key.new(:identity, identity_name, param_prop(@create["parameters"].find { it["name"] == identity_name })))
  end

  # {location} is the attribute location: required, replaced on change.
  def location(param) = ["location", Key.new(:location, "location", param_prop(param))]

  # Any other parameter before the identity names a parent: the attribute
  # <parent>_id, required, replaced on change, and checked against the
  # parent's id.
  def parent_key(param)
    path = @item.path[/\A.*?\{#{param["name"]}\}/]
    parent, = @api.items.find { |_, item| item.path == path } ||
      refuse("{#{param["name"]}}", "#{path} is not an item path, so the parameter names no parent; give it a GET")
    id = response_props(@api.paths[path]["get"] || {})["id"] || refuse(path, "no GET returns the parent's id, which the key is checked against; add one")
    ["#{parent}_id", Key.new(:parent_key, param["name"], id)]
  end

  # The provider addresses an object by id, so a rename never moves its address.
  def identity
    id = @response["id"] or refuse @get["operationId"], "the response has no id, by which the provider addresses the object; add it"
    doc = doc(id_source).schema["description"]
    Attr.new(name: "id", type: closed_types(id), flags: Set[:computed, :stable], doc:, default: nil, checks: [], why: [[:identity, "{#{identity_name}}"], [:stable, id.at]])
  end

  def id_source = Source.new("id", nil, nil, @response["id"])

  # A path with each placeholder named after the attribute it fills. The
  # engine reads an import id as the attributes after the scope.
  def in_attributes(path, identity)
    names = @keys.to_h { |attr, key| [key.param, attr] }.merge(identity_name => identity)
    path.gsub(/\{(\w+)\}/) { "{#{names.fetch($1, $1)}}" }
  end

  # The create is the POST on the collection, else the POST on the item.
  def create_op
    path = [@item.path.delete_suffix("/{#{identity_name}}"), @item.path].find { @api.paths.dig(it, "post") }
    [path, @api.paths[path]["post"]] if path
  end

  def create
    return unless @create
    Create.new("POST", in_attributes(@create_path, "name"), @create_body.keys.sort, [[:create_op, @create["operationId"]], *create_response])
  end

  # The engine reads with the GET on the item, and deletes with its DELETE.
  def crud_ops
    if @create
      missing = %w[get delete] - @api.paths[@item.path].keys
      refuse @item.path, "a resource needs a GET and a DELETE on its item path; add the #{missing.map(&:upcase).join(" and ")}" if missing.any?
    elsif !@get
      refuse @item.path, "neither a resource, which needs a create, nor a datasource, which needs a GET"
    end
  end

  def create_response
    response = success(@create)
    schema = content(response)
    item = content(success(@get))
    accepted = [item, *item["allOf"]]
    return [] if accepted.include?(schema)
    return [union_collapse(response)] if (schema && (schema["anyOf"] || schema["oneOf"]))&.intersect?(accepted)
    refuse @create["operationId"], "the success response is not the item schema, its allOf base, or a union containing one, so it gives no id; return the item"
  end

  # union_collapse: the engine reads a union of the item and an array of
  # items as the item, and an array as a decode error.
  def union_collapse(response) = [:union_collapse, ref_name(response) || @create["operationId"]]

  # The keys, and the properties of the create body, the verb bodies and the
  # item GET's response. Properties of the same name make one attribute.
  def attribute_set
    ((@keys.keys | @request.keys | @response.keys) - ["id"]).map { Source.new(it, @keys[it], @request[it], @response[it]) }
  end

  def attribute(a)
    echo_agreement(a)
    immutable_readonly(a)
    flags = FLAGS.to_h { [it, send(it, a)] }
    name, type, from, of = typed(a.name, a.name, canonical(a), input?(a), attribute_set.map(&:name))
    checks, checked = checks(a)
    doc = doc(a)
    why = [*flags.values.grep(Array), ([:attr_type, canonical(a).at] unless type == :str), of, *checked, ([:doc, doc.at] unless doc == canonical(a))]
    Attr.new(name:, type:, flags: FLAGS.select { flags[it] }.to_set, doc: doc.schema["description"], default: default(a), checks: [*checks, from].compact, why: why.compact.uniq)
  end

  def input?(a) = a.key || a.req

  def canonical(a) = a.resp || a.req || a.key.check

  def default?(a) = a.req&.schema&.key?("default")

  # An attribute is required if it is a key, the name an identity fills, or
  # a property the create body requires without a default.
  def required(a) = a.key ? [a.key.rule, "{#{a.key.param}}"] : ([:required, a.req.at] if @required.include?(a.name) && !default?(a))

  def optional(a) = input?(a) && !required(a)

  # An attribute is computed if it is a response property that no input
  # carries, or an optional input that has a default or that the response
  # echoes. The server may fill in an echoed input that the configuration
  # leaves out. But one whose request property is nullable is not
  # computed, so that leaving it out sends null and clears the value.
  def computed(a)
    return [:computed, a.resp.at] unless input?(a)
    return unless optional(a)
    return [:default, a.req.at] if default?(a)
    [:computed, a.resp.at] if a.resp && !a.req.schema["nullable"]
  end

  def sensitive(a) = [a.req, a.resp].compact.find { it.schema["format"] == "password" }&.then { [:sensitive, it.at] }

  # A change to a create input that no verb owns replaces the resource.
  def replace(a)
    at = a.key ? "{#{a.key.param}}" : @create_body[a.name]&.at
    [:replace, at] if at && !@owned.include?(a.name)
  end

  # Besides id, a computed input and an x-immutable output keep their values
  # in a plan. Any other computed value is unknown after an update, since the
  # server may change it.
  def stable(a)
    return unless computed(a)
    return [:stable, a.req.at] if input?(a)
    [:stable, a.resp.at] if a.resp.schema["x-immutable"]
  end

  def write_only(a) = ([:write_only, a.req.at] if a.req&.schema&.dig("writeOnly"))

  def nullable(a) = ([:attr_type, canonical(a).at] if canonical(a).schema["nullable"])

  # The framework default makes the provider always send the value, so a
  # later change of the server's default cannot cause drift.
  def default(a)
    return unless default?(a)
    value = a.req.schema["default"]
    Call.new(DEFAULTS[value.class] || refuse(a.req.at, "a default of #{value.inspect} has no framework default; remove it"), [value])
  end

  # An attribute's name and type, and, where rule ids applies, its ids_of
  # option and the rule's provenance. var names the variable of an object
  # nested in the attribute.
  def typed(name, var, prop, input, names) = (ids(name, prop, names) unless input) || [name, attr_type(var, prop, input)]

  # ids: an object in a response whose schema is an item schema of a type
  # the spec derives is that type's to describe, so the attribute holds
  # only the object's id, typed as that type's id. The type need not be
  # defined, so that defining a type changes no other type's attributes. A
  # type's item schemas are those its item GET's response names by $ref,
  # itself or as an allOf member. The attribute is the property's name
  # with _id appended, or, for an array, with a final s dropped and _ids
  # appended, as firewalls gives firewall_ids. The option ids_of names the
  # property that the engine reads the objects from.
  def ids(name, prop, names)
    schema = prop.schema
    array = schema["type"] == "array"
    id = item_ids.values_at(*refs(array ? schema.fetch("items", {}) : schema)).compact.first or return
    attr, type = if array then ["#{name.delete_suffix("s")}_ids", Call.new(schema["uniqueItems"] ? :set_of : :list_of, [closed_types(id)])]
    else ["#{name}_id", closed_types(id)]
    end
    refuse prop.at, "rule ids names it #{attr}, which is already a property; rename one" if names.include?(attr)
    [attr, type, Call.new(:ids_of, [name]), [:ids, id.at]]
  end

  # The id property of each type the spec derives, by the $ref of each of
  # its item schemas.
  def item_ids
    @item_ids ||= @api.items.values.filter_map { @api.paths[it.path]["get"] }.flat_map do |get|
      refs(content(success(get)) || {}).map { [it, response_props(get)["id"]] }
    end.to_h
  end

  def attr_type(name, prop, input)
    schema = prop.schema
    if object?(schema) then nesting(name, :single, prop, input)
    elsif object_array?(schema) then nesting(name, schema["uniqueItems"] ? :set : :list, Prop.new(schema["items"], prop.at), input)
    else closed_types(prop)
    end
  end

  # Types map by this closed table. A string maps by its format, and any
  # other format is only documentation.
  def closed_types(prop)
    schema = prop.schema
    union = schema.key?("anyOf") || schema.key?("oneOf") || schema["format"] == "binary"
    type = case schema["type"]
    when "array" then Call.new(schema["uniqueItems"] ? :set_of : :list_of, [closed_types(Prop.new(schema.fetch("items", {}), prop.at))])
    when "object" then Call.new(:map_of, [closed_types(Prop.new(schema["additionalProperties"], prop.at))]) if schema["additionalProperties"].is_a?(Hash)
    when "string" then FORMATS.fetch(schema["format"], :str)
    else SCALARS[schema["type"]]
    end
    return type if type && !union
    refuse prop.at, "no attribute type fits; give it one type: string, integer, boolean, an array, an object with properties, or a map with typed additionalProperties"
  end

  def object?(schema) = schema["type"] == "object" && schema.key?("properties")

  def object_array?(schema) = schema["type"] == "array" && object?(schema.fetch("items", {}))

  # An object nests to any depth, unless rule ids holds only its id. The
  # spec has no cycle to cut, since Api resolves each $ref in place, which
  # a cycle would not allow. A nested object's variable is named after the
  # attribute, or after the object it is in and the property.
  def nesting(name, kind, prop, input)
    at = ref_name(prop.schema) || prop.at
    required = prop.schema.fetch("required", [])
    inner = properties(prop.schema, at).reject { |_, s| s["deprecated"] }
    attrs = inner.map do |n, s|
      part = Prop.new(s, "#{at}.#{n}")
      a = input ? Source.new(n, nil, part, nil) : Source.new(n, nil, nil, part)
      rule = input ? :optional : :computed
      rule = :required if input && required.include?(n)
      flags = {rule => [rule, part.at]}.merge(sensitive: sensitive(a), nullable: nullable(a)).compact
      attr, type, from, of = typed(n, "#{name}_#{n}", part, input, inner.keys)
      checks, checked = checks(a)
      why = [*flags.values, ([:attr_type, part.at] unless type == :str), of, *checked]
      Attr.new(name: attr, type:, flags: FLAGS.select { flags[it] }.to_set, doc: doc(a).schema["description"], default: nil, checks: [*checks, from].compact, why: why.compact.uniq)
    end
    Nested.new(kind, "o_#{name}", attrs.sort_by(&:name), [[:nesting, prop.at]])
  end

  # Each check comes from the request property, else the response's, but the
  # response's enum is the vocabulary where the request is looser: the server
  # may accept TCP and store tcp. Go's RE2 has no lookaround and no
  # backreferences, so a pattern with them is skipped. A string's bounds are
  # on its length. Outputs have no checks, and only strings and integers
  # have any, since the engine checks no other type.
  def checks(a)
    type = canonical(a).schema["type"]
    return [[], []] unless input?(a) && %w[string integer].include?(type)
    props = a.key ? [a.key.check] : [a.req, a.resp].compact
    bounds = (type == "string") ? %w[minLength maxLength] : %w[minimum maximum]
    found = ["enum", "pattern", *bounds].to_h { |k| [k, ((k == "enum") ? props.reverse : props).find { it.schema.key?(k) }] }
    enum, pattern, min, max = found.values
    re2 = pattern && !pattern.schema["pattern"].match?(/\(\?<?[=!]|\\[1-9k]/)
    lo, hi = min&.schema&.dig(bounds[0]), max&.schema&.dig(bounds[1])
    calls = [
      (Call.new(:one_of, enum.schema["enum"]) if enum),
      (Call.new(:matches, [pattern.schema["pattern"]]) if re2),
      (Call.new(:at_least, [lo]) if lo),
      (Call.new(:at_most, [hi]) if hi),
    ]
    why = found.values.compact.map { [:checks, (it == pattern && !re2) ? "#{it.at}!re2" : it.at] }
    [calls.compact, why.uniq]
  end

  # An attribute's description is the response property's, else the request
  # property's, else the parameter's; a parent key takes the description of
  # the parent's id.
  def doc(a)
    props = (a.key&.rule == :parent_key) ? [a.key.check] : [a.resp, a.req, a.key&.check].compact
    props.find { it.schema["description"] } || described(canonical(a).at)
  end

  def described(at) = refuse(at, "no description; add one")

  # The candidates are the PATCH on the item, and each POST or PATCH with a
  # body on a direct literal subroute. A subroute with paths beneath it is a
  # child type's collection, and is skipped. A candidate is a verb if its
  # body holds only properties of the create body or the item response, or
  # writeOnly ones.
  def verb_candidates
    base = @item.path
    subroutes = @api.paths.keys.select { |path| path.match?(%r{\A#{Regexp.escape(base)}/[^/{}]+\z}) && @api.paths.keys.none? { it.start_with?("#{path}/") } }
    found = [[base, "patch"], *([[base, "post"]] if item_post_verb), *subroutes.product(%w[patch post])]
    found.filter_map { |path, method| candidate(path, method, @api.paths[path][method]) }.sort_by { [it.path, it.method] }
  end

  def candidate(path, method, op)
    return unless op && op["requestBody"] && !op["deprecated"]
    id = op["operationId"]
    body = body(op)
    aside = if merge_subroute(path, method) then :merge_subroute
    elsif name_carrier(path, body) then :name_carrier
    elsif body.any? { |n, prop| !(@create_body.key?(n) || @response.key?(n) || prop.schema["writeOnly"]) } then :verb_candidates
    end
    origin = (path == @item.path && method == "post") ? :item_post_verb : :verb_candidates
    Candidate.new(path, method, id, body, [[aside || origin, id]], !aside)
  end

  # item_post_verb: when the create is on the collection, the POST on the
  # item is a candidate too.
  def item_post_verb = @create_path != @item.path

  # merge_subroute: a PATCH on a subroute merges into a sub-document and
  # cannot express a removed key.
  def merge_subroute(path, method) = path != @item.path && method == "patch"

  # name_carrier: a subroute body that carries the name with other
  # properties names a new object.
  def name_carrier(path, body) = path != @item.path && body.key?("name") && body.size > 1

  # The verbs that the definition's order names run first, then the item's
  # verbs, then the subroutes' verbs by path. A verb on a subroute is named
  # after it, and one on the item is patch or post.
  def verb_order(candidates)
    verbs = candidates.select(&:verb).to_h { [(it.path == @item.path) ? it.method.to_sym : it.path.split("/").last.tr("-", "_").to_sym, it] }
    order = @facts.fetch(:order, [])
    unknown = order - verbs.keys
    refuse "definitions #{@name} order", "#{unknown.join(", ")} names no verb#{"; the verbs are #{verbs.keys.join(", ")}" if verbs.any?}" if unknown.any?
    first = verbs.values_at(*order)
    first.map { it.with(why: [[:verb_order, "definitions.rb"], *it.why]) } + (candidates - first)
  end

  # An attribute belongs to the first verb that carries it, and a verb that
  # owns nothing is dropped.
  def verb_owner(candidates)
    owned = []
    candidates.map do |c|
      next c unless c.verb
      next c.with(why: [[:verb_owner, c.id]], verb: false) if (c.body.keys - owned).empty?
      owned |= c.body.keys
      c
    end
  end

  def statement(c) = c.verb ? Verb.new(c.method.upcase, c.path.delete_prefix(@item.path), c.body.keys.sort, c.why) : Dropped.new(c.id, c.why)

  # x-lifecycle on a property lists the values in which the object is still
  # pending, and those in which it has failed.
  def lifecycle
    marked = @response.select { |_, prop| prop.schema.key?("x-lifecycle") }
    lifecycle_enum(marked)
    marked.flat_map do |name, prop|
      prop.schema["x-lifecycle"].slice("pending", "failed").map { |kind, values| LIFECYCLE[kind].new(name, values.sort, [[:lifecycle, prop.at]]) }
    end
  end

  def lifecycle_enum(marked)
    refuse @get["operationId"], "x-lifecycle marks #{marked.keys.join(" and ")}; mark one" if marked.size > 1
    marked.each_value do |prop|
      lifecycle = prop.schema["x-lifecycle"]
      unless lifecycle.is_a?(Hash) && (lifecycle.keys - LIFECYCLE.keys).empty? && lifecycle.values.all? { it.is_a?(Array) && it.all?(String) }
        refuse prop.at, "x-lifecycle needs an object whose pending and failed members list strings"
      end
      listed = lifecycle.values_at(*LIFECYCLE.keys).flatten.compact
      next if prop.schema["readOnly"] && (listed - prop.schema.fetch("enum", [])).empty?
      refuse prop.at, "x-lifecycle needs a readOnly property whose enum lists #{listed.join(", ")}"
    end
  end

  def immutable_readonly(a)
    [a.req, a.resp].compact.each { |prop| refuse prop.at, "x-immutable without readOnly; it marks outputs only" if prop.schema["x-immutable"] && !prop.schema["readOnly"] }
  end

  def response_direction
    @response.each do |name, prop|
      next if prop.schema["readOnly"] || @keys.key?(name) || @request.key?(name)
      refuse prop.at, "neither readOnly nor accepted by an input; mark it readOnly, or accept it in the create or a verb"
    end
  end

  def input_echo
    [@create_body, *@verbs.select(&:verb).map(&:body)].each do |body|
      body.each { |name, prop| refuse prop.at, "neither in the response nor writeOnly; mark it writeOnly or echo it" unless @response.key?(name) || prop.schema["writeOnly"] }
    end
  end

  # A request may be looser than the response that echoes it, and nullable
  # may differ.
  def echo_agreement(a)
    return unless a.req && a.resp && !accepts?(a.req.schema, a.resp.schema)
    refuse a.req.at, "accepts less than #{a.resp.at} returns; make the request accept every value the response allows"
  end

  def accepts?(req, resp)
    return (req["anyOf"] || req["oneOf"]).any? { accepts?(it, resp) } if req["anyOf"] || req["oneOf"]
    req["type"] == resp["type"] && [nil, resp["format"]].include?(req["format"]) &&
      (!req["enum"] || resp["enum"]&.difference(req["enum"])&.empty?) &&
      %w[items additionalProperties].all? { |k| !(req[k].is_a?(Hash) && resp[k].is_a?(Hash)) || accepts?(req[k], resp[k]) }
  end

  # An attribute's example comes from its request property, else its path
  # parameter (or, for a parent key, the parent's id), else its response
  # property. Each of these may give an example, or else an examples entry
  # named after the attribute: a reference parameter has no example, only
  # examples named id and name. The create body's example, where the spec
  # gives one, comes before all of these.
  def example(body) = [id_source, *attribute_set].to_h { [it.name, example_of(it)] }.compact.merge(body)

  # A resource's example sets the required inputs, and the properties that
  # the create body's example sets. That example is a whole body the API
  # accepts, where the property examples may not be: a body can need one of
  # several optional inputs. A property of that example that the body does
  # not offer as an input, such as a deprecated one, is left out.
  def body_example = (@create&.dig("requestBody", "content", "application/json", "schema", "example") || {}).slice(*@create_body.keys).compact

  def example_of(a) = candidates(a).flat_map { [it.schema["example"], it.schema.dig("examples", a.name, "value")] }.compact.first

  def candidates(a) = [a.req, a.key&.check, a.resp].compact

  # A parent key holds its parent's id, and an input whose pattern is the
  # id pattern of exactly one other type holds that type's id. A resource's
  # example sets such an attribute to the id of that type's example.
  def references(inputs) = inputs.to_h { [it.name, reference(it)] }.compact

  def reference(attr)
    return attr.name.delete_suffix("_id") if @keys[attr.name]&.rule == :parent_key
    pattern = attr.checks.find { it.name == :matches }&.args&.first or return
    types = @api.items.except(@name).select { |_, item| id_pattern(item) == pattern }.keys
    types.first if types.one?
  end

  # The other type need not be defined, so its spec is read without the
  # invariants, which hold for defined types only.
  def id_pattern(item) = content(success(@api.paths[item.path]["get"] || {}))&.dig("properties", "id", "pattern")

  # The generated examples need a value for each path parameter, required
  # attribute and id.
  def examples(values)
    params = @item.params.map { param_prop(it) }.reject { it.schema.slice("example", "examples").compact.any? }
    attrs = [id_source, *attribute_set.select { required(it) }].reject { values.key?(it.name) }.map { candidates(it).first }
    missing = [*params, *attrs]
    refuse missing.map(&:at).join(", "), "no example; add one to each" if missing.any?
  end

  def response_props(op)
    name = response_name(op)
    properties(content(success(op)) || {}, name).filter_map { |n, s| [n, Prop.new(s, "#{name}.#{n}")] unless s["deprecated"] }.to_h
  end

  def response_name(op) = ref_name(success(op)) || op["operationId"]

  def body(op)
    id = op["operationId"]
    properties(content(op["requestBody"]) || {}, id).filter_map { |n, s| [n, Prop.new(s, "#{id}.#{n}")] unless s["readOnly"] || s["deprecated"] }.to_h
  end

  def properties(schema, at)
    typed_allof(schema, at)
    schema.fetch("properties", {})
  end

  def typed_allof(schema, at)
    refuse at, "an allOf member lacks type: object; add it" if schema.fetch("allOf", []).any? { it["type"] != "object" }
  end

  def param_prop(param) = Prop.new(param.fetch("schema", {}).merge(param.slice("description", "example", "examples")), "{#{param["name"]}}")

  def success(op) = op.fetch("responses", {}).find { |code, _| code.start_with?("2") }&.last

  def content(node) = node&.dig("content", "application/json", "schema")

  def ref_name(node) = node&.dig("$ref")&.split("/")&.last

  def refs(schema) = [schema, *schema["allOf"]].filter_map { it["$ref"] }
end
