# frozen_string_literal: true

# Reflection-driven generator for the terraform provider's Go source.
# See doc/terraform-generator.md for architecture and workflow.
module TerraformGenerator
  class ResourceDefinition
    attr_reader :name, :serializer_class, :serializer_options, :fixture_block, :attr_options

    def initialize(name)
      @name = name
      @serializer_options = {}
      @attr_options = {}
    end

    # Optional coverage cross-check, with fixture below: name the API
    # serializer and a block assembling (not saving) a representative
    # row; generation fails if the row's serialized keys and the
    # derived schema disagree.
    def serializer(klass, **options)
      @serializer_class = klass
      @serializer_options = options
    end

    def fixture(&block)
      @fixture_block = block
    end

    # Annotate one attribute; dotted paths reach nested fields
    # ("firewall_rules.protocol"). kinds: scopes the annotation, and
    # multiple declarations for one path merge, so curation can differ
    # per emitted artifact.
    def attr(path, kinds: %i[datasource resource], **options)
      (@attr_options[path.to_s] ||= []) << {options:, kinds:}
    end

    def attr_options_for(dotted, kind)
      (@attr_options[dotted] || []).each_with_object({}) do |decl, merged|
        merged.merge!(decl[:options]) if decl[:kinds].include?(kind)
      end
    end

    # Which artifacts to emit; both by default, declare only to narrow.
    def kinds(*ks) = @kinds = ks
    def emitted_kinds = @kinds || [:datasource, :resource]

    def route(fragment) = @route_fragment = fragment
    def route_fragment = @route_fragment || name.to_s

    # Sample paths anchor reflection to concrete spec operations;
    # override when routes deviate from /project/../location/../<x>/<name>
    # (project lives at /project; firewall_rule creates on its parent).
    # rubocop:disable Style/TrivialAccessors -- DSL: positional setters read as declarations
    def details_sample(path) = @details_sample = path
    def create_sample(path) = @create_sample = path
    # rubocop:enable Style/TrivialAccessors
    def create_sample_path = @create_sample || details_sample_path
    def details_sample_path = @details_sample || "/project/x/location/y/#{route_fragment}/z"

    # Map path params to terraform attributes when the default
    # (project_id, location, name) does not hold - project keys on id.
    def key_attrs(map) = @key_attrs = map.transform_keys(&:to_s)

    # One way the resource updates. route: :patch means PATCH on the
    # details path; a string names a POST subroute (method: overrides
    # its verb); macro: instead names a clover route macro. attrs: the
    # terraform attributes whose change triggers it, derived from the
    # operation's request body when omitted (union or bodyless
    # operations must declare). exclusive: must be the only change in
    # a plan. tombstones: :server_union - the endpoint merges maps, so
    # removed keys are sent as explicit nulls. blocked_when:
    # {attr:, summary:, detail:} refuses the verb whenever attr is set
    # in state (postgres: a set parent marks a read replica). order:
    # :last defers dispatch
    # (rename: earlier verbs must address the old name). recovery:
    # :persist_name writes the new name to state before later steps
    # can fail. also_after_create: runs once after create as well.
    def update_verb(name, attrs: nil, route: nil, macro: nil, order: nil,
      blocked_when: nil, recovery: nil, also_after_create: false,
      tombstones: nil, method: :post, exclusive: false)
      update_verbs << {name:, attrs: attrs&.map(&:to_s), route:, macro:,
        order:, blocked_when:, recovery:, also_after_create:, tombstones:, method:, exclusive:}
    end

    def update_verbs = @update_verbs ||= []

    def ordered_update_verbs
      update_verbs.partition { it[:order] != :last }.flatten
    end

    # Every per-attribute treatment lives in one table, declared
    # via attr(path, **flags) - the named forms below are sugar.
    #   write_only      never echoed; mappers preserve/default (spec
    #                   writeOnly derives this; the sugar remains for
    #                   fields the spec cannot annotate)
    #   volatile        wall-clock computed; updates pin to plan
    #   unread_map      value behind its own GET; unknowns -> null map
    #   stable          read-only computed no verb touches; ModifyPlan
    #                   pins it in update plans
    #   omit            not exposed in the terraform schema
    def write_only(*keys) = keys.each { attr(it, write_only: true) }
    def volatile(*keys) = keys.each { attr(it, volatile: true) }
    def unread_map(*keys) = keys.each { attr(it, unread_map: true) }
    def stable_computed(*keys) = keys.each { attr(it, stable: true) }

    # Async lifecycle: wait(:create, state:) polls the details GET
    # until state matches; wait(:delete) until 404. timeout/poll are
    # defaults; UBICLOUD_<RESOURCE>_* env overrides at runtime.
    def wait(kind, timeout:, state: nil, poll: "10s")
      waits[kind] = {state:, timeout:, poll:}
    end

    def waits = @waits ||= {}

    # Plan-modifier exclusions:
    #   moving     the server changes it on its own or as a verb side
    #              effect; never UseStateForUnknown
    #   updatable  changes server-side outside any declared verb;
    #              never RequiresReplace
    def moving(*keys) = keys.each { attr(it, moving: true) }
    def updatable(*keys) = keys.each { attr(it, updatable: true) }
    # Plan modifiers are derived only for resources that opt in; a
    # definition without this line publishes a schema with none.
    # (Historical opt-in - unifying changes published schemas and
    # needs its own reviewed golden diff.)
    def derive_plan_modifiers! = @derive_plan_modifiers = true
    def derive_plan_modifiers? = !!@derive_plan_modifiers

    def flagged(flag, kind: nil)
      @attr_options.filter_map do |path, decls|
        path if decls.any? { it[:options][flag] && (kind.nil? || it[:kinds].include?(kind)) }
      end
    end

    def key_attr_for(param)
      (@key_attrs || {})[param] ||
        {"project_id" => :project_id, "location" => :location}[param] ||
        :name
    end

    # Exclude API fields from the terraform schema; dotted paths reach
    # nested fields, kinds: scopes per artifact. Unmatched omissions
    # fail generation (consumed_omits).
    def omit(*keys, kinds: %i[datasource resource])
      keys.each { attr(it, omit: true, kinds:) }
    end

    def omitted = @attr_options.select { |_, decls| decls.any? { it[:options][:omit] } }.keys
    def omitted?(dotted, kind) = attr_options_for(dotted, kind)[:omit]
    # Populated by reflection as omissions match; unmatched entries
    # fail generation.
    def consumed_omits = @consumed_omits ||= []
  end

  @resources = {}

  class << self
    attr_reader :resources

    def resource(name, &block)
      definition = ResourceDefinition.new(name)
      definition.instance_eval(&block)
      @resources[name] = definition
    end

    def [](name) = @resources.fetch(name)

    def load_definitions!
      Dir[File.expand_path("terraform_generator/resources/*.rb", __dir__)].sort.each { require it }
    end
  end
end

require_relative "terraform_generator/reflection"
require_relative "terraform_generator/schema"
