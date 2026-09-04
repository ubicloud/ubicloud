# frozen_string_literal: true

require "json"

module TerraformGenerator
  # One attribute of the API response, derived from the openapi
  # schema. Committee validates live requests and responses against
  # the same document, so both directions of the mapper seam read one
  # tested contract.
  Attribute = Struct.new(:key, :json_type, :pointer, :enum, :format, :nested, :client_type, :path, :options, :schema_description) do
    # tf-side name; `tf:` option covers API/schema fields the terraform
    # schema renamed (ip4_enabled -> enable_ip4).
    def tf_key = (options[:tf] || key).to_s

    # Assignment expression for a create request-body field from a tf
    # state value; pointer fields assign inside a null/unknown guard.
    # cast: named client enum type for this body's field, when the
    # schema declares one (owned here so both directions of the
    # table live on the attribute).
    def body_assign(expr, cast: nil)
      if (w = options[:wrap_write])
        wrapped = "#{w}(#{expr}.ValueString())"
        return pointer ? "strP(#{wrapped})" : wrapped
      end
      if json_type == "string_list"
        elem = cast ? "ubicloud_client.MaintenanceWindowDay" : "string"
        slice = "stringSliceFrom[#{elem}](#{expr})"
        return pointer ? "sliceP(#{slice})" : slice
      end
      base = case [json_type, pointer]
      in ["string", true] then "#{expr}.ValueStringPointer()"
      in ["string", false] then "#{expr}.ValueString()"
      in ["integer", true] then "intPointer(#{expr}.ValueInt64())"
      in ["integer", false] then "int(#{expr}.ValueInt64())"
      in ["boolean", true] then "#{expr}.ValueBoolPointer()"
      in ["boolean", false] then "#{expr}.ValueBool()"
      else raise "no body assignment for #{key}: #{[json_type, pointer].inspect}"
      end
      return base unless enum && cast
      pointer ? "(*#{cast})(#{base})" : "#{cast}(#{base})"
    end

    def go_field = tf_key.split("_").map(&:capitalize).join
    def api_go_field = key.to_s.split("_").map(&:capitalize).join
    def tf_name = tf_key
    def path_camel = (path + [key.to_s]).map { it.split("_").map(&:capitalize).join }.join

    # The closed conversion vocabulary, keyed by (json_type, pointer,
    # enum). pointer means the Go field is a pointer - nullable or not
    # required - so an absent value stays distinguishable from the
    # zero value.
    def conversion(expr, prior: nil)
      if (w = options[:wrap_read])
        return "#{w}(#{prior || "state.#{go_field}"}.ValueString(), #{expr})"
      end
      return "stringListValue(#{expr})" if json_type == "string_list" && !pointer
      return "stringListValue(derefSlice(#{expr}))" if json_type == "string_list"

      case [json_type, pointer, enum, format]
      in ["string", false, false, "date-time"] then "types.StringValue(#{expr}.Format(iso8601Layout))"
      in ["string", false, false, _] then "types.StringValue(#{expr})"
      in ["string", false, true, _] then "types.StringValue(string(#{expr}))"
      in ["string", true, false, _] then "types.StringPointerValue(#{expr})"
      in ["integer", false, _, _] then "types.Int64Value(int64(#{expr}))"
      in ["integer", true, _, _] then "int64PointerValue(#{expr})"
      in ["boolean", false, _, _] then "types.BoolValue(#{expr})"
      in ["number", false, _, _] then "types.Float64Value(float64(#{expr}))"
      else raise "no conversion for #{key}: #{[json_type, pointer, enum, format].inspect} (extend the table)"
      end
    end
  end

  module Reflection
    module_function

    # openapi_parser template-matches concrete paths the same way
    # committee does at runtime, so the generator provably reads the
    # operation the validator enforces.
    def details_operation(definition)
      path = definition.details_sample_path
      Clover::OPENAPI.request_operation(:get, path) ||
        raise("no GET operation matches #{path}; check the resource's route/details_sample")
    end

    # Ordered (openapi param, tf attr) key pairs from the matched
    # operation's own path template.
    def sibling_operation(definition, method)
      path = (method == :post) ? definition.create_sample_path : definition.details_sample_path
      Clover::OPENAPI.request_operation(method, path) ||
        raise("no #{method.upcase} operation at #{path}")
    end

    # requestBody attributes for the create POST; pointer here means
    # optional in the body (the emitted client renders non-required
    # body fields as pointers with omitempty).
    def create_body_attributes(definition, operation)
      body = operation.operation_object.request_body
      return [] unless body
      eff = effective(body.content["application/json"].schema)
      attrs = attributes_from_schema(eff, definition, ["__create__"], kind: :resource)
      # Bare-name declarations apply to body attrs too (their walk path
      # is __create__-prefixed); walk-path options win on conflict.
      attrs.each { it.options = definition.attr_options_for(it.key.to_s, :resource).merge(it.options) }
      # A bare-name omit reaches body attrs here, past the dotted-path
      # filter: drop and mark consumed (firewall_rule's firewall_id
      # duplicates its own path key in the create body).
      attrs.reject { it.options[:omit] }.tap do
        (attrs - it).each { |a| definition.consumed_omits << a.key.to_s }
      end
    end

    def verb_operation(definition, verb)
      if verb[:route] == :patch
        Clover::OPENAPI.request_operation(:patch, definition.details_sample_path)
      else
        sub = verb[:route] || verb[:macro].to_s
        Clover::OPENAPI.request_operation(verb[:method], "#{definition.details_sample_path}/#{sub}")
      end or raise "no operation for update verb #{verb[:name]}"
    end

    def verb_read_operation(definition, verb)
      sub = verb[:route] || verb[:macro].to_s
      Clover::OPENAPI.request_operation(:get, "#{definition.details_sample_path}/#{sub}") or
        raise "tombstone verb #{verb[:name]} needs a GET at its subroute"
    end

    # The operation's request body IS the mutability
    # declaration; attrs derive from it unless curated (postgres
    # :patch withholds tags). Resolved for every verb - including
    # tombstone/exclusive ones that bypass body_attrs - so the
    # exclusivity check sees real lists. Bodyless or macro verbs must
    # declare.
    def resolve_verb_attrs!(verb, operation)
      return if verb[:attrs]
      body = operation&.operation_object&.request_body or
        raise "verb #{verb[:name]}: no request body to derive attrs from; declare attrs:"
      derived = effective(body.content["application/json"].schema)[:properties].keys
      raise "verb #{verb[:name]}: request body has no derivable properties (union or empty); declare attrs:" if derived.empty?
      verb[:attrs] = derived
    end

    def verb_body_attributes(definition, verb, operation)
      body = operation.operation_object.request_body
      eff = effective(body.content["application/json"].schema)
      missing = verb[:attrs] - eff[:properties].keys
      raise "verb #{verb[:name]}: attrs not in its request body: #{missing.join(", ")}" if missing.any?
      attributes_from_schema(eff, definition, ["__#{verb[:name]}__"], kind: :resource)
        .select { verb[:attrs].include?(it.key.to_s) }
    end

    def key_pairs(definition, operation)
      operation.original_path.scan(/\{(\w+)\}/).flatten
        .map { [it, definition.key_attr_for(it)] }
    end

    # openapi path-parameter patterns, keyed by tf attr; they become
    # the key attributes' regex validators.
    def key_patterns(definition, operation)
      params = (operation.operation_object.parameters || []) +
        (operation.path_item&.parameters || [])
      key_pairs(definition, operation).filter_map do |param, attr|
        pattern = params.find { it.name == param }&.schema&.pattern
        [attr.to_s, pattern] if pattern
      end.to_h
    end

    def response_schema(operation)
      resolve_response(operation.operation_object.responses.response["200"]
        .content["application/json"].schema)
    end

    # Item-or-array-of-Item unions - oneOf or anyOf spelled - (firewall_rule's batch-capable
    # create) resolve to the Item branch at the door: generated code
    # creates singly, and every downstream consumer - naming, walking,
    # struct emission - then sees a plain component. An array response
    # leaves JSON200 nil and fails closed at the existing guard.
    def resolve_response(schema)
      return schema unless (branches = schema.one_of || schema.any_of)
      obj = branches.find { it.type != "array" }
      arr = branches.find { it.type == "array" }
      if branches.length == 2 && obj && arr&.items&.object_reference == obj.object_reference
        return obj
      end
      raise "response oneOf shape not yet supported (extend when first needed)"
    end

    # openapi_parser resolves $refs but (correctly) leaves allOf
    # structure for the validator; merge members for effective
    # properties/required; later members override earlier.
    def effective(schema)
      members = schema.all_of || [schema]
      members.each_with_object({properties: {}, required: []}) do |m, eff|
        sub = m.all_of ? effective(m) : {properties: m.properties || {}, required: m.required || []}
        eff[:properties].merge!(sub[:properties])
        eff[:required] |= sub[:required]
      end
    end

    # openapi_parser deduplicates: a resolved $ref node IS the shared
    # component object, whose object_reference names it; an inline
    # unresolved ref falls back to its raw form.
    def component_name(schema)
      # Named schema components, and response components (the
      # generated JSON200 struct is named after the response component
      # for allOf-shaped detailed responses).
      if (m = %r{\A#/components/(?:schemas|responses)/(\w+)}.match(schema.object_reference.to_s))
        return m[1]
      end
      ref = schema.raw_schema["$ref"] if schema.raw_schema.is_a?(Hash)
      ref&.split("/")&.last or
        raise "schema at #{schema.object_reference} is not a named component; nested mappers need a named client type"
    end

    # Attribute set for an arbitrary response schema, with the
    # definition's omit filtering applied.
    def attributes_from_schema_filtered(schema, definition, kind)
      attributes_from_schema(effective(schema), definition, [], kind:)
    end

    # Called after every declared kind has rendered: an omit no kind
    # consumed is a typo.
    def validate_omits!(definition)
      unknown = definition.omitted - definition.consumed_omits
      raise "omit lists unknown fields: #{unknown.join(", ")}" if unknown.any?
    end

    def attributes_for(definition)
      operation = details_operation(definition)
      attrs = attributes_from_schema(effective(response_schema(operation)), definition, [], kind: :datasource)
      assert_serializer_agreement!(definition, attrs) if definition.fixture_block
      [attrs, operation.operation_object.operation_id.sub(/\A./) { it.upcase }, key_pairs(definition, operation)]
    end

    def upcase_op(operation) = operation.operation_object.operation_id.sub(/\A./) { it.upcase }

    def attributes_from_schema(eff, definition, path, kind: :datasource)
      eff[:properties].filter_map do |key, schema|
        dotted = (path + [key]).join(".")
        if definition.omitted?(dotted, kind)
          definition.consumed_omits << dotted
          next
        end
        # Native OpenAPI semantics as declaration-equivalent defaults:
        # the route author annotates at the source; declarations
        # override. format: password => sensitive; readOnly =>
        # computed; writeOnly => write-only (accepted, never echoed).
        semantics = {}
        semantics[:sensitive] = true if schema.format == "password"
        # readOnly speaks to the API's response contract; datasource
        # keys are terraform inputs regardless, so the computed default
        # is resource-kind only.
        semantics[:classification] = :computed if schema.read_only && kind == :resource
        semantics[:write_only] = true if schema.write_only
        options = semantics.merge(definition.attr_options_for(dotted, kind))
        pointer = !!schema.nullable || !eff[:required].include?(key)
        if schema.type == "array" && schema.items&.type == "object"
          Attribute.new(key:, options:, path:, client_type: component_name(schema.items),
            schema_description: schema.description,
            nested: attributes_from_schema(effective(schema.items), definition, path + [key], kind:))
        elsif schema.type == "array" && schema.items&.type == "string"
          Attribute.new(key:, json_type: "string_list", pointer:,
            enum: !schema.items.enum.nil?, path:, options:,
            schema_description: schema.description)
        elsif schema.type == "object" && schema.additional_properties&.type == "string"
          Attribute.new(key:, json_type: "map", path:, options: options.merge(map: true),
            schema_description: schema.description)
        elsif schema.type == "object" || schema.type == "array"
          raise "#{dotted}: #{schema.type} shape not yet supported (extend when first needed)"
        else
          # ipv4/ipv6 formats render as plain client strings; date-time
          # as time.Time.
          fmt = %w[date-time].include?(schema.format) ? schema.format : nil
          Attribute.new(key:, json_type: schema.type, pointer:, enum: !schema.enum.nil?,
            format: fmt, path:, options:, schema_description: schema.description)
        end
      end.sort_by(&:tf_name)
    end

    # Cross-check: the serializer, executed against an assembled
    # fixture and read at the wire, must emit only keys the
    # schema declares, with agreeing scalar shapes. Catches schema
    # coverage gaps at generation time, before any test would.
    def assert_serializer_agreement!(definition, attrs)
      serialized = nil
      DB.transaction(rollback: :always, auto_savepoint: true) do
        object = definition.fixture_block.call
        serialized = definition.serializer_class.serialize(object, definition.serializer_options)
      end
      wire = JSON.parse(serialized.to_json)
      by_key = attrs.to_h { [it.tf_name, it] }
      wire.each do |key, value|
        next if definition.omitted.include?(key)
        attr = by_key[key] or raise "serializer emits #{key.inspect}, absent from the openapi schema"
        next if attr.nested || value.nil?
        expected = {"string" => String, "integer" => Integer, "boolean" => [TrueClass, FalseClass]}.fetch(attr.json_type)
        unless Array(expected).any? { value.is_a?(it) }
          raise "serializer emits #{key.inspect} as #{value.class}, schema says #{attr.json_type}"
        end
      end
    end

    def comparable(eff)
      eff[:properties].to_h do |key, schema|
        [key, [schema.type, !!schema.nullable, schema.enum, eff[:required].include?(key)]]
      end
    end

    def vendored_mismatch(definition, what)
      "openapi drift for #{definition.name} (#{what}): the provider's vendored " \
        "config/ubicloud_openapi.yml disagrees with clover's openapi/openapi.yml. " \
        "Resync the vendored spec and regenerate the client before generating."
    end
  end
end
