# frozen_string_literal: true

# Prints, as JSON, what examples_harness.rb needs of each generated
# resource type. It runs in a process of its own, so that clover's never
# loads the generator.
require "json"
require_relative "../../terraform/lib/terraform_generator"

tg = TerraformGenerator
resources = tg.types.select { |type| type.statements.any?(tg::Create) }
puts JSON.generate(resources.map do |type|
  attrs = type.statements.grep(tg::Attr).to_h do |a|
    kind = case a.type
    when Symbol then a.type
    when tg::Call then a.type.name
    else :object
    end
    [a.name, {kind:, flags: a.flags.to_a, checks: a.checks.to_h { [it.name, it.args] }}]
  end
  {
    name: type.name, item: type.item, named: type.statements.grep(tg::Datasource).first.lookup.include?("name"),
    attrs:, verbs: type.statements.grep(tg::Verb).map { {method: it.method, path: it.path, body: it.body} }, examples: type.examples,
  }
end)
