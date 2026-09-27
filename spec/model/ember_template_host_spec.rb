# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe EmberTemplateHost do
  it "reports whether the host has finished building" do
    template = create_ember_template
    host = create_ember_host
    row = described_class.create(ember_template_id: template.id, vm_host_id: host.id)
    expect(row).not_to be_ready
    row.update(state: "ready")
    expect(row).to be_ready
    expect(row.ember_template_id).to eq(template.id)
    expect(row.vm_host.id).to eq(host.id)
  end
end
