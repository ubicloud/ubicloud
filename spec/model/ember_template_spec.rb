# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe EmberTemplate do
  let(:template) { create_ember_template }

  it "generates ct-prefixed ubids" do
    expect(described_class.generate_ubid.to_s).to start_with("ct")
  end

  it "reports whether it can be restored from" do
    expect(template).to be_ready
    template.update(state: "building")
    expect(template).not_to be_ready
  end

  describe "#ready_hosts" do
    it "lists only the hosts that finished building" do
      ready = create_ember_host
      building = create_ember_host
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: ready.id, state: "ready")
      EmberTemplateHost.create(ember_template_id: template.id, vm_host_id: building.id, state: "building")
      expect(template.reload.ready_hosts.map(&:id)).to eq([ready.id])
    end
  end
end
