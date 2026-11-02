# frozen_string_literal: true

module TerraformGenerator
  SPEC = File.expand_path("../../openapi/openapi.yml", __dir__)
  SpecError = Class.new(StandardError)

  # One terraform type: its name, its item path written in attribute names,
  # its description, and its statements.
  Type = Data.define(:name, :item, :doc, :statements, :why)

  # Each statement but Dropped renders as one builder call in the generated
  # Go: the call is named after the record's class, and its members other
  # than why are the arguments. why lists the rules that shaped the
  # statement, each with the spec location it read, as [rule, location]
  # pairs.
  Create = Data.define(:method, :path, :body, :why)
  Datasource = Data.define(:lookup, :why)
  Pending = Data.define(:attr, :values, :why)
  Failed = Data.define(:attr, :values, :why)
  Attr = Data.define(:name, :type, :flags, :doc, :default, :checks, :why)
  Verb = Data.define(:method, :path, :body, :why)
  Dropped = Data.define(:operation, :why) # a candidate verb that a rule set aside; rendered as a comment

  Call = Data.define(:name, :args) # a call in an argument: Call.new(:list_of, [:str]) is listOf(str)

  # An attribute's object type, of kind :single, :list or :set. It renders
  # as var := object(), with why as the comment above it.
  Nested = Data.define(:kind, :var, :attrs, :why)

  # The order in which an attribute's flags are written.
  FLAGS = %i[required optional computed sensitive replace stable write_only nullable].freeze

  def self.types(api = Api.load, definitions = Definitions::TYPES) = definitions.map { |name, facts| Derive.new(api, name, facts).type }

  # Each definition key and each rule clause that shaped a type, with the
  # types it shaped, so that review sees every special case by name.
  def self.special_cases(api = Api.load, definitions = Definitions::TYPES)
    keys = definitions.flat_map { |name, facts| facts.keys.map { ["definitions #{it}", name] } }
    clauses = types(api, definitions).flat_map do |type|
      (type.statements.flat_map { it.why.map(&:first) } & Derive::CLAUSES).map { [it.to_s, type.name.to_sym] }
    end
    (keys + clauses).group_by(&:first).sort.to_h { |name, uses| [name, uses.map(&:last).uniq.sort] }
  end
end

require_relative "terraform_generator/api"
require_relative "terraform_generator/definitions"
require_relative "terraform_generator/derive"
