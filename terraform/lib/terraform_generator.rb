# frozen_string_literal: true

require "digest"

module TerraformGenerator
  SPEC = File.expand_path("../../openapi/openapi.yml", __dir__)
  MODULE = File.expand_path("../provider", __dir__)
  SpecError = Class.new(StandardError)

  # One terraform type: its name, its item path written in attribute names,
  # its description, and its statements. examples gives the example value
  # of each attribute that has one, example_inputs names the attributes
  # that a resource's example sets, and references gives, for each of those
  # that holds another type's id, the name of that type.
  Type = Data.define(:name, :item, :doc, :statements, :examples, :example_inputs, :references, :why)

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

  # A generated file's one header line names the command that writes it
  # and the one that shows what is left to carry back of an edit.
  HEADER = "rake terraform:generate; rake terraform:diff"

  def self.types(api = Api.load, definitions = Definitions::TYPES) = definitions.map { |name, facts| Derive.new(api, name, facts).type }

  # The text of each generated file, keyed by its path in the module. Hcl
  # takes all the types at once, because one type's example can include
  # another's.
  def self.files(api = Api.load, definitions = Definitions::TYPES)
    types = types(api, definitions)
    [*types.map { Go.file(it) }, *Hcl.files(types)].to_h
  end

  # The header ends in a stamp, the start of the body's SHA-256, by which
  # the generator can tell a file whose body was edited from one it may
  # overwrite.
  def self.stamped(comment, body) = "#{comment} #{HEADER}; sha256:#{stamp(body)}\n#{body}"

  def self.stamp(body) = Digest::SHA256.hexdigest(body)[0, 16]

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
require_relative "terraform_generator/go"
require_relative "terraform_generator/hcl"
require_relative "terraform_generator/tree"
