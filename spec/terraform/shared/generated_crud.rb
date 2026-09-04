# frozen_string_literal: true

# A definition-driven CRUD
# baseline. Gate paths derive from the definition's sample paths; the
# id assertion from its schema; per-resource divergence lives in
# RESOURCE_REGISTRY hooks. Three lines in generated_crud_spec.rb buy a
# new resource its gated create barrier, server-id adoption, read, and
# gated delete-to-gone regression forever.
module TerraformHarness
  module CrudDerivation
    module_function

    # Sample paths use single-letter placeholders for keys; the name
    # key becomes the concrete fixture name, other keys match anything.
    def gate_path(sample, name)
      last = sample.split("/").last
      segs = sample.split("/").map do |seg|
        next seg unless seg.match?(/\A[a-z]\z/)
        (seg.equal?(last) || seg == last) ? Regexp.escape(name) : "[^/]+"
      end
      %r{#{segs.join("/")}\z}
    end

    def has_id_attr?(definition)
      TerraformGenerator::Schema.spec_for(definition, :resource)["schema"]["attributes"]
        .any? { it["name"] == "id" }
    end
  end
end

RSpec.shared_examples "generated resource CRUD" do |resource_name|
  it "runs the gated create/read/delete baseline" do
    reg = TerraformHarness::RESOURCE_REGISTRY.fetch(resource_name, {})
    # Convention defaults: model by name, find by first-name,
    # address ubicloud_<name>.r, fixture derived - a conforming
    # resource needs zero registry lines.
    reg = {find: ->(n) { TerraformHarness.model_for(resource_name).first(name: n) },
           address: "ubicloud_#{resource_name}.r"}.merge(reg)
    definition = TerraformGenerator[resource_name]
    reg[:prepare]&.call(self)
    name = reg[:name_fixed] || "gen-#{resource_name.to_s.tr("_", "-")}"
    runner = tf_runner(reg[:fixture] || derived_fixture(definition), name:)

    create_path = reg[:create_path] ||
      TerraformHarness::CrudDerivation.gate_path(definition.create_sample_path, name)
    create_gate = tf_gate(method: "POST", path: create_path)
    apply = tf_async { runner.apply }
    create_gate.wait_for_arrival
    expect(reg[:find].call(name)).to be_nil
    create_gate.release
    if reg[:converge_create]
      # The released request is in flight; the row lands when clover
      # commits it. Poll briefly, then hand the hook a real row.
      row = nil
      50.times do
        break if (row = reg[:find].call(name))
        sleep 0.05
      end
      # No row means the create failed server-side; fall through so
      # apply.value raises with the response body.
      reg[:converge_create].call(self, row) if row
    end
    apply.value

    row = reg[:find].call(name)
    expect(row).not_to be_nil
    reg[:after_create]&.call(self, row)
    if TerraformHarness::CrudDerivation.has_id_attr?(definition)
      attrs = runner.state_resources.find { it["address"] == reg[:address] }["values"]
      expect(attrs["id"]).to eq row.ubid
    end

    delete_path = if reg[:delete_path]
      reg[:delete_path].call(row)
    else
      %r{#{definition.details_sample_path.split("/").map { it.match?(/\A[a-z]\z/) ? "[^/]+" : it }.join("/")}\z}
    end
    delete_gate = tf_gate(method: "DELETE", path: delete_path)
    destroy = tf_async { runner.run!("destroy", "-auto-approve", "-no-color") }
    delete_gate.wait_for_arrival.release
    reg[:converge_delete]&.call(self, row)
    destroy.value

    expect(runner.state_resources).to be_nil
    if reg[:gone]
      instance_exec(self, reg[:find].call(name), &reg[:gone])
    else
      expect(reg[:find].call(name)).to be_nil
    end
  end
end
