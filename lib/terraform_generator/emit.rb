# frozen_string_literal: true

require "fileutils"

require "erb"
require "open3"

module TerraformGenerator
  # Rendering and orchestration: the ERB control-flow templates,
  # per-resource contexts, atomic write_all (render and gofmt
  # everything before writing anything), and the freshness map
  # terraform:check compares against. Data-shaped Go lives in the
  # Declarations sibling.
  module Emit
    module_function def go_field(tf) = tf.to_s.split("_").map(&:capitalize).join

    TEMPLATES = File.expand_path("templates", __dir__)

    module GoHelpers
      def camelize(str) = str.to_s.split("_").map(&:capitalize).join

      def render_partial(file, locals)
        template = File.read(File.join(TEMPLATES, file))
        b = binding
        locals.each { |k, v| b.local_variable_set(k, v) }
        ERB.new(template, trim_mode: "-").result(b)
      end

      def model_type
        Declarations.model_name(@definition, kind_sym)
      end

      def schema_expr
        "#{camel}#{kind_word}Schema(ctx)"

      end

      def client_type_ref(t)
        (t == "struct{}") ? t : "api#{t}"
      end

      def nested_elem_type(a)
        "types.ObjectType{AttrTypes: #{Declarations.attr_types_fn(@definition, a, kind_sym)}()}"
      end

      def nested_new_elem(a)
        "types.ObjectValueMust(#{Declarations.attr_types_fn(@definition, a, kind_sym)}(), "
      end

      def details_call
        api_call(details_component, "GET", path_format_of(@definition.details_sample_path), key_call_args, "nil")
      end

      def verb_path_format(v)
        base = path_format_of(@definition.details_sample_path)
        return base if v[:route] == :patch
        "#{base}/#{v[:route] || v[:macro]}"
      end

      def verb_http_method(v)
        return "PATCH" if v[:route] == :patch || v[:method] == :patch
        "POST"
      end

      def verb_call(v, body: "body")
        api_call("struct{}", verb_http_method(v.spec), verb_path_format(v.spec), key_call_args, body)
      end

      def verb_read_call(v, component)
        api_call(component, "GET", "#{path_format_of(@definition.details_sample_path)}/#{v.spec[:route] || v.spec[:macro]}", key_call_args, "nil")
      end

      def config_body_type = "api#{camel}PatchConfig"

      def body_cast_for(a, op)
        nil
      end

      def api_call(component, method, path_fmt, args, body)
        "apiCall[#{client_type_ref(component)}](ctx, #{uc_holder}, \"#{method}\", fmt.Sprintf(\"#{path_fmt}\", #{args}), #{body})"
      end

      def path_format_of(sample)
        sample.split("/").map { it.match?(/\A[a-z]\z/) ? "%s" : it }.join("/")
      end

      # The err/status guard pair every verb call wears, emitted
      # verbatim at the arms' closure depth. Not indent-corrected:
      # the body is the generated source, column zero, real tabs.
      def verb_guard(v, resp: "apiResp")
        log = "#{camel_lower}ResourceLogIdentifier(state)"
        <<-GO.chomp
				if err != nil {
					diags.Append(apiFailErr("applying #{v.name} to", "#{human}", #{log}, err)...)
					return diags
				}
				if #{resp}.StatusCode() != http.StatusOK {
					diags.Append(apiFailStatus("applying #{v.name} to", "#{human}", #{log}, #{resp}.Status(), #{resp}.Body)...)
					return diags
				}
        GO
      end
    end

    class DatasourceContext
      include GoHelpers

      attr_reader :name, :attributes, :details_op

      def initialize(definition)
        @definition = definition
        @name = definition.name.to_s
        @attributes, @details_op, @key_pairs = Reflection.attributes_for(definition)
      end

      # Go model fields for the key, in call order, e.g.
      # ["ProjectId", "Location", "Name"].
      attr_reader :key_pairs
      def key_fields = @key_pairs.map { |_, attr| camelize(attr) }
      def key_call_args = key_fields.map { "state.#{it}.ValueString()" }.join(", ")
      def log_identifier_format = @key_pairs.map { |_, a| "#{a}=%s" }.join(", ")

      def camel = @name.split("_").map(&:capitalize).join
      def camel_lower = camel.sub(/\A./) { it.downcase }
      def human = @name.tr("_", " ")

      def scalar_attributes = attributes.reject(&:nested)
      def nested_attributes = attributes.select(&:nested)

      # get<X><Nested>State, unexported: one mapper per (datasource,
      # nested attr), in this file.
      def nested_mapper_name(a) = "get#{camel}#{a.path_camel}State"

      # All nested attributes at every depth, parents before children,
      # so the template emits one mapper per (datasource, path) and
      # parents can call child mappers.
      def all_nested(attrs = attributes)
        attrs.select(&:nested).flat_map { [it, *all_nested(it.nested)] }
      end

      def lower(s) = camelize(s).sub(/\A./) { it.downcase }
      def log_call = "#{camel_lower}#{kind_word}LogIdentifier(#{log_arg})"
      def kind_word = "DataSource"
      def kind_sym = :datasource
      def uc_holder = "d.uc"
      def timeouts_block? = Schema.spec_for(@definition, :resource)["schema"]["blocks"]&.any? { it["name"] == "timeouts" }

      def details_component = Reflection.component_name(Reflection.response_schema(Reflection.details_operation(@definition)))
      def log_arg = "&state"

      # A $ref component's name is its Go struct's name.
      def nested_client_type(a) = a.client_type

      def render
        template = File.read(File.join(TEMPLATES, "datasource.go.erb"))
        ERB.new(template, trim_mode: "-").result(binding)
      end
    end

    class ResourceContext < DatasourceContext
      Mapper = Struct.new(:client_type, :attrs) do
        def fn_name(camel) = "set#{camel}StateFrom#{client_type}"
        def scalar = attrs.reject(&:nested)
        def nested = attrs.select(&:nested)
      end

      def initialize(definition)
        super
        create = Reflection.sibling_operation(definition, :post)
        @create_op = Reflection.upcase_op(create)
        @create_key_pairs = Reflection.key_pairs(definition, create)
        @create_body = Reflection.create_body_attributes(definition, create)
        @delete_op = Reflection.upcase_op(Reflection.sibling_operation(definition, :delete))

        # Create and Read may return different response components
        # (firewall: base Firewall vs FirewallDetailed); one canonical
        # mapper per component consumed.
        @mappers = {}
        [Reflection.details_operation(definition), create].each do |op|
          schema = Reflection.response_schema(op)
          ct = Reflection.component_name(schema)
          @mappers[ct] ||= Mapper.new(client_type: ct,
            attrs: Reflection.attributes_from_schema_filtered(schema, definition, :resource))
        end
        @read_mapper = @mappers[Reflection.component_name(Reflection.response_schema(Reflection.details_operation(definition)))]
        @create_mapper = @mappers[Reflection.component_name(Reflection.response_schema(create))]
      end

      attr_reader :create_op, :delete_op, :read_mapper, :create_mapper
      Verb = Struct.new(:spec, :op, :body_attrs, :read_op) do
        def name = spec[:name]
        def go_op(upcaser) = upcaser.call(op)
      end

      # Every attr of the non-exclusive verbs, for the exclusivity
      # guard an exclusive arm emits.
      def non_exclusive_attr_fields
        @definition.update_verbs.reject { it[:exclusive] }
          .flat_map { it[:attrs] }.uniq.map { camelize(it) }
      end

      def update_verbs
        @update_verbs ||= @definition.ordered_update_verbs.map do |spec|
          op = Reflection.verb_operation(@definition, spec)
          Reflection.resolve_verb_attrs!(spec, op)
          read_op = (spec[:tombstones] || spec[:exclusive]) &&
            Reflection.upcase_op(Reflection.verb_read_operation(@definition, spec))
          Verb.new(spec:, op: Reflection.upcase_op(op), read_op:,
            body_attrs: (spec[:tombstones] || spec[:exclusive]) ? [] : Reflection.verb_body_attributes(@definition, spec, op))
        end
      end

      def waits = @definition.waits

      # Data for the shared _wait partial: one skeleton, per-wait deltas.
      def wait_specs
        json200 = "*#{client_type_ref(read_mapper.client_type)}, diag.Diagnostics"
        specs = []
        if waits[:create]
          specs << {suffix: "State", extra_param: "want string, ", ret: json200,
            fail_ret: "nil, diags", match: "apiResp.JSON200.State == want",
            want_fmt: "state %q", want_args: "want, ",
            until_doc: "the reported state matches", timeout_tail: "", gone: false}
        end
        if update_verbs.any? { it.spec[:exclusive] }
          specs << {suffix: "Version", extra_param: "want string, ", ret: json200,
            fail_ret: "nil, diags", match: "string(apiResp.JSON200.Version) == want",
            want_fmt: "version %q", want_args: "want, ",
            until_doc: "the reported version matches", timeout_tail: " upgrade", gone: false}
        end
        if waits[:delete]
          specs << {suffix: "Gone", extra_param: "", ret: "diag.Diagnostics",
            fail_ret: "diags", match: nil, want_fmt: "deletion", want_args: "",
            until_doc: "the row is gone (404)", timeout_tail: " deletion", gone: true}
        end
        specs
      end

      def go_duration(str) = "#{str.sub("s", "")} * time.Second".sub(/\A(\d+) \* time.Second\z/) { "#{$1} * time.Second" }
      def env_prefix = "UBICLOUD_#{@name.upcase}"
      def adoption_spec = @definition.adoption_spec
      def stable_computed_fields = @definition.flagged(:stable).map { camelize(it) }
      def volatile_fields = @definition.flagged(:volatile).map { camelize(it) }
      def unread_map_fields = @definition.flagged(:unread_map).map { camelize(it) }

      # Declarations or spec writeOnly - the create walk carries
      # the derived flag on attribute options, so union both sources.
      def write_only_fields
        (@definition.flagged(:write_only) +
          create_body_attributes.select { it.options[:write_only] }.map { it.key.to_s })
          .uniq.map { camelize(it) }
      end

      def response_mappers = @mappers.values

      # Create's own path params (may be empty: project).
      def create_key_call_args
        args = @create_key_pairs.map { |_, a| "state.#{camelize(a)}.ValueString()" }
        args.empty? ? "" : args.join(", ") + ", "
      end

      def create_body_attributes = @create_body

      # Distinct from the datasource file's mapper names (same Go
      # package) and per-component.
      def kind_word = "Resource"
      def kind_sym = :resource
      def uc_holder = "r.uc"

      def details_component = read_mapper.client_type

      def create_body_type
        "api#{camel}CreateBody"
      end

      def create_call
        api_call(create_mapper.client_type, "POST", path_format_of(@definition.create_sample_path), create_key_call_args.chomp(", "), "body")
      end

      def delete_call
        api_call("struct{}", "DELETE", path_format_of(@definition.details_sample_path), key_call_args, "nil")
      end

      def nested_mapper_name(a) = "get#{camel}Resource#{a.path_camel}State"
      def resource_all_nested = response_mappers.flat_map { all_nested(it.attrs) }.uniq(&:path_camel)

      def render
        template = File.read(File.join(TEMPLATES, "resource.go.erb"))
        ERB.new(template, trim_mode: "-").result(binding)
      end
    end

    module_function

    def provider_repo
      ENV["UBICLOUD_TF_PROVIDER_REPO"] || File.expand_path("../../tmp/terraform-provider-ubicloud", __dir__)
    end

    def gofmt(source, label)
      out, err, status = Open3.capture3("gofmt", stdin_data: source)
      raise "gofmt failed for #{label}:\n#{err}" unless status.success?
      out
    end

    def datasource_source(name)
      context = DatasourceContext.new(TerraformGenerator[name])
      gofmt(context.render, "#{name} datasource")
    end

    def datasource_path(name)
      File.join(provider_repo, "internal", "provider", "#{name}_datasource.go")
    end

    # Diff mode: render against the file on disk without writing.
    def datasource_diff(name)
      generated = datasource_source(name)
      out, _status = Open3.capture2("diff", "-u", datasource_path(name), "-", stdin_data: generated)
      out
    end

    def write_datasource(name)
      File.write(datasource_path(name), datasource_source(name))
      datasource_path(name)
    end

    def resource_path(name)
      File.join(provider_repo, "internal", "provider", "#{name}_resource.go")
    end

    def resource_source(name)
      gofmt(ResourceContext.new(TerraformGenerator[name]).render, "#{name} resource")
    end

    # Constant Go lives as Go: interpolated generation stays in
    # Ruby heredocs and ERB; this file is neither, so it gets syntax,
    # gofmt, and freedom from the heredoc-escaping bug class.
    GEN_SUPPORT = File.read(File.expand_path("support/gen_support.go", __dir__))

    def write_gen_support
      path = File.join(provider_repo, "internal", "provider", "gen_support.go")
      File.write(path, GEN_SUPPORT)
      path
    end

    # Atomic: render EVERYTHING first (any template or gofmt failure
    # aborts before a single byte lands), then write. The spike's
    # recurrence of the stale-artifact trap - declaration files written, CRUD
    # aborted, build green on stale - earned this shape.
    # The module scaffold: everything a buildable provider module needs
    # that no definition derives - go.mod and go.sum, main, the provider
    # wiring, the support packages, their tests, the docs templates and
    # tool shim - carried verbatim under support/tree, plus the goldens
    # (owned here, copied into the module's testdata for its Go tests).
    # Generation therefore yields a complete module from an empty
    # directory; the provider repo is a publishing target, not an input.
    SCAFFOLD_ROOT = File.join(__dir__, "support", "tree")

    def scaffold_sources
      out = Dir.glob("**/*", File::FNM_DOTMATCH, base: SCAFFOLD_ROOT)
        .select { File.file?(File.join(SCAFFOLD_ROOT, it)) }
        .to_h { [File.join(provider_repo, it), File.read(File.join(SCAFFOLD_ROOT, it))] }
      testdata = File.join(provider_repo, "internal", "provider", "testdata")
      out[File.join(testdata, "schema_goldens.json")] = File.read(Schema.goldens_path)
      out[File.join(testdata, "wire_goldens.json")] = File.read(Schema.wire_goldens_path)
      out
    end

    def write_all(name)
      definition = TerraformGenerator[name]
      fresh = {}
      fresh.merge!(scaffold_sources)
      fresh.merge!(Declarations.sources(definition))
      fresh[File.join(provider_repo, "internal", "provider", "gen_support.go")] = GEN_SUPPORT
      definition.emitted_kinds.each do |kind|
        fresh[send(:"#{kind}_path", name)] = send(:"#{kind}_source", name)
      end
      Reflection.validate_omits!(definition)
      fresh.each do |path, content|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      # Auto-golden for brand-new resources only; existing goldens are
      # the authority and change solely via rake terraform:goldens.
      Schema.write_goldens!([name], only_missing: true)
      fresh.keys.each { puts it }
    end
  end
end
