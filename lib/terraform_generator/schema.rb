# frozen_string_literal: true

require "fileutils"

module TerraformGenerator
  # The schema plane: derives each resource's terraform schema
  # (classifications, descriptions, sensitivity, plan modifiers,
  # validators, blocks) from the same reflected attribute sets the code
  # templates use. Two consumers: Emit::Declarations renders it to Go, and the
  # self-goldens below pin it against regression.
  module Schema
    module_function

    JSON_TO_SPEC_TYPE = {
      "string" => "string", "integer" => "int64",
      "boolean" => "bool", "number" => "float64",
    }.freeze

    # The full provider schema for one (definition, kind), as a plain
    # hash: "schema" => {"attributes" => [...], "blocks" => [...]},
    # each attribute carrying its type entry with classification,
    # description, sensitivity, validators, and plan modifiers - the
    # form the Go renderer consumes and the goldens snapshot. The
    # resource kind builds an emit context so classifications see
    # exactly the mapper and create-body sets the code templates
    # render: one derivation, two consumers.
    def spec_for(definition, kind)
      ctx = Emit::ResourceContext.new(definition) if kind == :resource
      attrs = (kind == :resource) ? ctx.read_mapper.attrs : Reflection.attributes_for(definition)[0]
      body = (kind == :resource) ? ctx.create_body_attributes : []
      op = Reflection.details_operation(definition)
      keys = Reflection.key_pairs(definition, op).map { _2.to_s }
      key_patterns = Reflection.key_patterns(definition, op)

      verb_attrs = definition.update_verbs.flat_map { it[:attrs] } +
        ((definition.update_verbs.any? { it[:macro] == :rename }) ? ["name"] : [])
      create_plane = (kind == :resource) ?
        (Emit::ResourceContext.new(definition).create_body_attributes.map(&:tf_name) +
         keys + definition.flagged(:inject, kind: :resource)) : []
      schema = {
        "name" => definition.name.to_s,
        "schema" => {"attributes" => begin
          base = attrs.map { attribute_entry(it, definition, kind, body:, keys:, verb_attrs:, create_plane:, key_patterns:) }
          extra = injected_attributes(definition, kind, keys:, verb_attrs:, create_plane:, key_patterns:)
            .reject { |e| base.any? { it["name"] == e["name"] } }
          (base + extra).sort_by { it["name"] }
        end},
      }
      if kind == :resource && definition.waits.any?
        schema["schema"]["blocks"] = [TIMEOUTS_BLOCK]
      end
      schema
    end

    def attribute_entry(a, definition, kind, body:, keys:, verb_attrs: [], create_plane: [], key_patterns: {}, nested: false)
      entry = {"name" => a.tf_name}
      if a.nested
        cls = classification(a, definition, kind, body:, keys:)
        entry["list_nested"] = {
          "computed_optional_required" => cls,
          "nested_object" => {"attributes" => a.nested.map { attribute_entry(it, definition, kind, body: [], keys: [], nested: true) }},
          "description" => description(a),
          "plan_modifiers" => ((kind == :resource) ? plan_modifiers(a, definition, "list_nested", classification: cls, verb_attrs:, create_plane:) : nil),
        }.compact
      else
        type = case a.json_type
        when "map" then "map"
        when "string_list" then "list"
        else JSON_TO_SPEC_TYPE.fetch(a.json_type)
        end
        cls = classification(a, definition, kind, body:, keys:)
        entry[type] = {
          "computed_optional_required" => cls,
          "description" => description(a),
          "sensitive" => (true if a.options[:sensitive]),
          "element_type" => (%w[map string_list].include?(a.json_type) ? {"string" => {}} : nil),
          "plan_modifiers" => ((kind == :resource && !nested) ? plan_modifiers(a, definition, type, classification: cls, verb_attrs:, create_plane:) : nil),
          "validators" => begin
            vals = Array((kind == :resource) ? validators(a) : nil)
            if (pattern = key_patterns[a.tf_name])
              vals = [custom("github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator", "regexp",
                "stringvalidator.RegexMatches(regexp.MustCompile(#{pattern.inspect}), \"\")")] + vals
            end
            vals.empty? ? nil : vals
          end,
        }.compact
      end
      entry
    end

    # Datasources: keys are required lookups, everything else computed.
    # Resources: keys required; create-body attrs echoed in the response
    # are computed_optional (server may default), body-only are optional;
    # response-only attrs are computed. Precedence: a declaration
    # (spec semantics keywords arrive through the same channel) beats
    # key role; key role beats body membership; body membership beats
    # the computed fallback.
    def classification(a, definition, kind, body:, keys:)
      declared = a.options[:classification]
      return declared.to_s if declared
      return keys.include?(a.tf_name) ? "required" : "computed" if kind == :datasource
      return "required" if keys.include?(a.tf_name)
      if body.any? { it.tf_name == a.tf_name }
        return "computed_optional"
      end
      "computed"
    end

    # Body-only attrs (never echoed: write_only, or absent from the
    # response like vm's create inputs the datasource hides) plus
    # declared injections (restore_target).
    def injected_attributes(definition, kind, keys:, verb_attrs: [], create_plane: [], key_patterns: {})
      # Details-path keys are rarely echoed in the response; inject them.
      key_entries = keys.map do |k|
        opts = definition.attr_options_for(k, kind)
        desc = opts[:description] || key_description(k, definition, kind)
        fake = TerraformGenerator::Attribute.new(key: k, json_type: "string", options: opts)
        cls = (opts[:classification] || :required).to_s
        vals = Array(validators(fake))
        if (pattern = key_patterns[k])
          vals = [custom("github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator", "regexp",
            "stringvalidator.RegexMatches(regexp.MustCompile(#{pattern.inspect}), \"\")")] + vals
        end
        {"name" => k, "string" => {
          "computed_optional_required" => cls,
          "description" => desc,
          "plan_modifiers" => ((kind == :resource) ? plan_modifiers(fake, definition, "string", classification: cls, verb_attrs:, create_plane:) : nil),
          "validators" => (vals.empty? ? nil : vals),
        }.compact}
      end
      return key_entries unless kind == :resource
      ctx = Emit::ResourceContext.new(definition)
      response_names = ctx.read_mapper.attrs.map(&:tf_name) + keys
      # An injected body attr whose ALIAS is echoed (size -> vm_size)
      # classifies as if echoed: the server reports it back.
      alias_targets = ctx.read_mapper.attrs.filter_map { it.options[:also_tf]&.to_s }
      body_entries = ctx.create_body_attributes.reject { response_names.include?(it.tf_name) }.map do |a|
        {"name" => a.tf_name,
         JSON_TO_SPEC_TYPE.fetch(a.json_type) => {
           "computed_optional_required" => (cls = a.options[:classification]&.to_s ||
             (if alias_targets.include?(a.tf_name)
                "computed_optional"
              else
                a.pointer ? "optional" : "required"
              end)),
           "description" => description(a),
           "plan_modifiers" => plan_modifiers(a, definition, JSON_TO_SPEC_TYPE.fetch(a.json_type), classification: cls, verb_attrs:, create_plane:),
           "validators" => validators(a),
         }.compact}
      end
      key_entries + body_entries + declared_injections(definition, kind)
    end

    # Lifted jq injections (restore_target; the create-body maps the
    # code plane defers): attr X, inject: {type:, classification:}.
    def declared_injections(definition, kind)
      definition.flagged(:inject, kind:).map do |path|
        spec = definition.attr_options_for(path, kind)[:inject]
        type = spec[:type].to_s
        body = {"computed_optional_required" => spec[:classification].to_s}
        body["description"] = spec[:description] if spec[:description]
        body["element_type"] = {"string" => {}} if type == "map"
        fake = TerraformGenerator::Attribute.new(key: path, json_type: type, options: definition.attr_options_for(path, kind))
        pm = plan_modifiers(fake, definition, type, classification: spec[:classification].to_s,
          verb_attrs: definition.update_verbs.flat_map { it[:attrs] },
          create_plane: [path])
        body["plan_modifiers"] = pm if pm
        v = validators(fake)
        body["validators"] = v if v
        {"name" => path, type => body}
      end
    end

    def description(a) = a.options[:description] || a.schema_description

    # Details-path keys have no response schema to describe them, so
    # texts derive by rule. Lookup keys accept id or name, and the
    # description says so.
    def key_description(k, definition, kind)
      case k
      when "project_id" then "ID of the project"
      when "location" then "The Ubicloud location/region"
      when /_reference\z/
        "#{k.delete_suffix("_reference").split("_").map(&:capitalize).join(" ")} ID or name"
      else
        base = (k == "name") ? definition.name.to_s.tr("_", " ") : k.split("_").map(&:capitalize).join(" ").sub(" Reference", "")
        # Lookup-style keys accept ID or name on both kinds; reference
        # keys (parent handles) carry it on the resource too.
        return "#{base.split.map(&:capitalize).join(" ")} ID or name" if kind == :datasource || k.end_with?("_reference")
        nil
      end
    end

    MODIFIER_PKG = {"string" => "stringplanmodifier", "int64" => "int64planmodifier",
                    "bool" => "boolplanmodifier", "map" => "mapplanmodifier",
                    "list_nested" => "listplanmodifier", "list" => "listplanmodifier", "float64" => "float64planmodifier"}.freeze

    def custom(*import_paths, definition)
      {"custom" => {"imports" => import_paths.map { {"path" => it} }, "schema_definition" => definition}}
    end

    def framework_modifier(spec_type, fn)
      pkg = MODIFIER_PKG.fetch(spec_type)
      custom("github.com/hashicorp/terraform-plugin-framework/resource/schema/#{pkg}", "#{pkg}.#{fn}()")
    end

    # UseStateForUnknown on computed and computed_optional attrs
    # the server does not move (an unset config pins to prior);
    # RequiresReplace on create-plane attrs no verb covers. USFU is
    # emitted BEFORE RequiresReplace so the pin happens first and a
    # matching prior never forces a spurious replace; the framework
    # applies modifiers in listed order.
    def plan_modifiers(a, definition, spec_type, classification:, verb_attrs:, create_plane:)
      return a.options[:plan_modifiers] if a.options[:plan_modifiers]
      return nil unless definition.derive_plan_modifiers?
      mods = []
      # Verb-covered configured attrs keep USFU (unset config pins to
      # prior); only values a verb itself MOVES (rename's name) join
      # the moving set, alongside declared server-shifted values.
      usfu_ok = %w[computed computed_optional].include?(classification) &&
        !a.options[:moving] && !moved_by_verb(definition).include?(a.tf_name)
      mods << framework_modifier(spec_type, "UseStateForUnknown") if usfu_ok
      Array(a.options[:extra_modifiers]).each { mods << custom(*it) }
      replace = a.options[:requires_replace] ||
        (create_plane.include?(a.tf_name) &&
         !verb_attrs.include?(a.tf_name) && !a.options[:updatable])
      mods << framework_modifier(spec_type, "RequiresReplace") if replace
      mods.empty? ? nil : mods
    end

    def validators(a) = a.options[:validators]&.map { custom(*it) }

    def moved_by_verb(definition)
      definition.update_verbs.select { it[:recovery] == :persist_name }
        .flat_map { it[:attrs] }
    end

    TIMEOUTS_BLOCK = {"name" => "timeouts", "single_nested" => {
      "custom_type" => {
        "import" => {"path" => "github.com/hashicorp/terraform-plugin-framework-timeouts/resource/timeouts"},
        "type" => "timeouts.Type{}", "value_type" => "timeouts.Value",
      },
      "attributes" => %w[create update delete].map {
        {"name" => it, "string" => {"computed_optional_required" => "optional"}}
      },
    }}.freeze

    # --- Schema self-goldens -------------------------------------
    # These goldens are the schema plane's authority going forward:
    # terraform:check diffs the FRESH derivation against them at full
    # fidelity (classifications, sensitivity, descriptions, modifiers,
    # validators, blocks) - the properties wire goldens cannot see and
    # check's freshness comparison structurally cannot catch. They are
    # deliberately NOT an auto-regenerated artifact: write_all appends
    # entries for brand-new resources only; changing an existing entry
    # requires an explicit `rake terraform:goldens`, making every
    # schema change a reviewed intent.
    # Goldens are owned here - they are the reviewed derivation - and
    # copied into the generated module's testdata for its Go tests.
    def goldens_path = File.join(__dir__, "goldens", "schema_goldens.json")

    def wire_goldens_path = File.join(__dir__, "goldens", "wire_goldens.json")

    def each_key(names)
      names.flat_map do |name|
        d = TerraformGenerator[name]
        d.emitted_kinds.map { |k| ["#{k}s/#{name}", d, k] }
      end
    end

    def golden_diff(names)
      goldens = File.exist?(goldens_path) ? JSON.parse(File.read(goldens_path)) : {}
      missing, diffs = [], []
      each_key(names).each do |key, d, kind|
        fresh = spec_for(d, kind)["schema"]
        golden = goldens[key]
        next missing << key unless golden
        diffs.concat(attr_diffs(key, fresh["attributes"], golden["attributes"]))
        if fresh["blocks"] != golden["blocks"]
          diffs << "#{key}.blocks: #{fresh["blocks"].inspect[0, 80]} vs golden #{golden["blocks"].inspect[0, 80]}"
        end
      end
      [missing, diffs]
    end

    # One line per attribute: the golden stays a reviewable artifact
    # (a diff shows the attribute that moved) at a fraction of the
    # pretty-printed size. Readers parse it as ordinary JSON.
    def dump_goldens(goldens)
      lines = ["{"]
      goldens.each_with_index do |(key, spec), i|
        lines << "  #{key.to_json}: {"
        spec.each_with_index do |(section, entries), j|
          comma = (j < spec.size - 1) ? "," : ""
          if entries.is_a?(Array)
            lines << "    #{section.to_json}: ["
            entries.each_with_index { |e, k| lines << "      #{JSON.generate(e)}#{"," if k < entries.size - 1}" }
            lines << "    ]#{comma}"
          else
            lines << "    #{section.to_json}: #{JSON.generate(entries)}#{comma}"
          end
        end
        lines << "  }#{"," if i < goldens.size - 1}"
      end
      lines << "}"
      lines.join("\n") + "\n"
    end

    def write_goldens!(names, only_missing: false)
      existing = File.exist?(goldens_path) ? JSON.parse(File.read(goldens_path)) : {}
      written = []
      each_key(names).each do |key, d, kind|
        next if only_missing && existing.key?(key)
        existing[key] = spec_for(d, kind)["schema"]
        written << key
      end
      if written.any?
        FileUtils.mkdir_p(File.dirname(goldens_path))
        File.write(goldens_path, dump_goldens(existing.sort.to_h))
      end
      written
    end

    # Full-fidelity attribute diff, fresh vs golden.

    SCALAR_DIFF_FIELDS = %w[computed_optional_required sensitive description].freeze
    LIST_DIFF_FIELDS = %w[plan_modifiers validators].freeze
    def attr_diffs(prefix, mine, theirs)
      out = []
      by_name = theirs.to_h { [it["name"], it] }
      mine.each do |m|
        t = by_name.delete(m["name"])
        next out << "#{prefix}.#{m["name"]}: not in golden" unless t
        mt, tt = [m, t].map { |e| e.keys.reject { it == "name" }.first }
        next out << "#{prefix}.#{m["name"]}: type #{mt} vs golden #{tt}" if mt != tt
        SCALAR_DIFF_FIELDS.each do |field|
          a, b = m[mt][field], t[tt][field]
          out << "#{prefix}.#{m["name"]}.#{field}: #{a.inspect} vs golden #{b.inspect}" if a != b
        end
        LIST_DIFF_FIELDS.each do |field|
          a = (m[mt][field] || []).map { it.dig("custom", "schema_definition") }
          b = (t[tt][field] || []).map { it.dig("custom", "schema_definition") }
          out << "#{prefix}.#{m["name"]}.#{field}: #{a.inspect} vs golden #{b.inspect}" if a != b
        end
        if mt == "list_nested"
          out.concat(attr_diffs("#{prefix}.#{m["name"]}",
            m[mt]["nested_object"]["attributes"], t[tt]["nested_object"]["attributes"]))
        end
      end
      by_name.each_key { out << "#{prefix}.#{it}: only in golden" }
      out
    end
  end
end
