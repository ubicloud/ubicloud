# frozen_string_literal: true

require "json"

# Go writes a Type as a Go file of builder calls, which the engine in
# terraform/provider interprets. Every line takes a form that gofmt leaves
# alone, so that formatting a generated file, as an editor may on save,
# does not make it differ from its render.
module TerraformGenerator::Go
  include TerraformGenerator

  NESTED = {single: :single, list: :list_of, set: :set_of}.freeze

  def self.file(type)
    lines = [comment(type.why), "t := newType(#{args([type.name, type.item, type.doc])})", *type.statements.flat_map { statement("t", it) }, "register(t)"]
    ["internal/provider/#{type.name}_gen.go", TerraformGenerator.stamped("//", "\npackage provider\n\nfunc init() {\n#{lines.map { "\t#{it}\n" }.join}}\n")]
  end

  # A nil member of the record is left out of the call, and the member
  # before why, which is a list in every statement record, is spread.
  def self.statement(receiver, s)
    return [comment(s.why)] if s.is_a?(Dropped)
    *values, rest = s.to_h.except(:why).values.compact
    values += rest
    objects = values.grep(Nested).flat_map { |o| [comment(o.why), "#{o.var} := object()", *o.attrs.flat_map { statement(o.var, it) }] }
    [*objects, comment(s.why), "#{receiver}.#{s.class.name.split("::").last.sub(/\A./, &:downcase)}(#{args(values)})"]
  end

  # A provenance comment is terse, like a debug symbol: each source once,
  # after the rules that read it, as rule,rule@source.
  def self.comment(why) = "// #{why.group_by(&:last).map { |at, pairs| "#{pairs.map(&:first).join(",")}@#{at}" }.join(" ")}"

  def self.args(values) = values.map { literal(it) }.join(", ")

  # A string with a backslash, such as a pattern, is written as a raw
  # string, so that it reads as it does in the spec. That won't do if it
  # holds a backquote, which would end the raw string, or a control
  # character, since Go drops a carriage return from a raw string and a
  # newline would split the statement across lines. Any other string is
  # written as JSON, which is a valid Go string.
  def self.literal(v)
    case v
    in Call then "#{camel(v.name)}(#{args(v.args)})"
    in Nested then "#{camel(NESTED.fetch(v.kind))}(#{v.var})"
    in Symbol then camel(v)
    in Set then v.map { camel(it) }.join("|")
    in String if v.include?("\\") && !v.match?(/[`\x00-\x1f]/) then "`#{v}`"
    in String then JSON.generate(v)
    in Integer | true | false then v.to_s
    end
  end

  def self.camel(name) = name.to_s.gsub(/_[a-z]/) { it[1].upcase }
end
