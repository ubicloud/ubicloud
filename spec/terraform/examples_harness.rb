# frozen_string_literal: true

require_relative "spec_helper"

# One loop tests every resource type through its generated examples, which
# the documentation shows, so each must work against the API. A
# datasource's example refers to its resource's, so the two are applied
# together. Then each update verb runs alone when one attribute it owns
# changes, a change to each input that forces replacement plans one, and
# the object imports by the id that the item path derives.
RSpec.describe "the generated examples" do
  examples = "#{TerraformHarness::ROOT}/terraform/provider/examples"

  # A second value for an input whose value the spec gives no other for:
  # an object input without an example.
  second_values = {"options" => {"headers" => {"x-example" => "1"}}}

  define_method(:second_values) { second_values }

  # The kinds of attribute whose second value the spec gives.
  derived = %w[boolean i64 str string_of]

  define_method(:config) { File.read("#{examples}/resources/#{address}/resource.tf") }

  def address = "ubicloud_#{type["name"]}"

  def attrs = type["attrs"]

  # The configuration with name set to value in the type's resource block.
  def set(hcl, name, value)
    hcl.sub(/^(resource "#{address}" "example" \{\n)(.*?)^\}/m) { "#{$1}#{$2.gsub(/^  #{name} += .*\n/, "")}  #{name} = #{JSON.generate(value)}\n}" }
  end

  # A value for the attribute other than current: the next value of its
  # enum, the other boolean, the next integer within its bound, a string
  # changed at its end and still matching its pattern, a map of the
  # spec's example with each value changed so, or, where current is null,
  # the spec's example.
  def second(name, current)
    return second_values[name] if second_values.key?(name)
    attr, example = attrs[name], type["examples"][name]
    return example if current.nil? && !example.nil? && attr["kind"] != "map_of"
    checks = attr["checks"]
    return checks["one_of"][(checks["one_of"].index(current) || -1).succ % checks["one_of"].size] if checks["one_of"]
    case attr["kind"]
    when "boolean" then !current
    when "i64" then (current.to_i < checks.fetch("at_most", [Float::INFINITY])[0]) ? current.to_i + 1 : current.to_i - 1
    when "str", "string_of" then mutate(current.to_s, checks.dig("matches", 0))
    when "map_of" then example&.transform_values { mutate(it.to_s, nil) }
    end
  end

  def mutate(s, pattern)
    re = pattern && Regexp.new(pattern)
    [s.sub(/\d+\z/) { (it.to_i + 1).to_s }, *[*"0".."9", *"a".."z"].map { s.chop + it }].find { it != s && (!re || re.match?(it)) }
  end

  def import_id(state)
    parts = type["item"].scan(/\{(\w+)\}/).flatten - ["project_id"]
    parts[-1] = "name" if type["named"]
    parts.map { state.fetch(it) }.join("/")
  end

  TerraformHarness.types.each do |type|
    name = "ubicloud_#{type["name"]}"
    describe name do
      let(:type) { type }

      it "applies #{name} with its datasource, and the datasource reads what the resource holds" do
        tf.apply config + File.read("#{examples}/data-sources/#{name}/data-source.tf")
        resource, data = "#{name}.example", "data.#{name}.example"

        expect(tf.state(data)).to eq tf.state(resource).slice(*tf.state(data).keys)
        expect(tf.sensitive(data)).to eq tf.sensitive(resource).slice(*tf.state(data).keys)
        expect(tf.plan).to be_empty
        tf.destroy
      end

      seen = []
      type["verbs"].each do |verb|
        owned, seen = verb["body"] - seen, seen | verb["body"]
        item = type["item"].delete_prefix("/project/{project_id}").delete_prefix("/location/{location}").delete_prefix("/")
        request = /\A#{verb["method"]} #{Regexp.escape(item + verb["path"]).gsub(/\\\{\w+\\\}/, "[^/]+")}\z/

        # An enum attribute starts at its first value, so that its second
        # is one the verb accepts, as an upgrade needs.
        it "sends #{verb["method"]} #{verb["path"].empty? ? "on the item" : verb["path"]} of #{name} alone when an attribute it owns changes" do
          attr = owned.find { |n| derived.include?(attrs[n]["kind"]) || (attrs[n]["kind"] == "map_of" && type["examples"][n]) }
          enum = attrs[attr]["checks"]["one_of"]
          start = enum ? set(config, attr, enum[0]) : config
          tf.apply start
          value = second(attr, tf.state("#{name}.example")[attr])

          expect(tf.apply(set(start, attr, value)).mutations).to match [request]
          expect(tf.plan).to be_empty
        end
      end

      replaced = type["attrs"].select { |_, a| a["flags"].include?("replace") }.keys
      if replaced.any?
        it "plans to replace #{name} when #{replaced.join(", ")} changes" do
          tf.apply config
          state = tf.state("#{name}.example")

          aggregate_failures do
            replaced.each { |n| expect(tf.plan(set(config, n, second(n, state[n]))).actions).to include("#{name}.example" => :replace), n }
          end
        end
      end

      it "imports #{name} by the id that its item path derives, and plans no change" do
        tf.apply config
        state = tf.state("#{name}.example")
        tf.run "state", "rm", "#{name}.example"

        expect(tf.apply(<<~HCL + config).mutations).to be_empty
        import {
          to = #{name}.example
          id = "#{import_id(state)}"
        }
        HCL
        expect(tf.state("#{name}.example")["id"]).to eq state["id"]
        expect(tf.plan).to be_empty
      end
    end
  end
end
