# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe UsageAlert do
  it "trigger sends email and updates last_triggered_at" do
    alert = described_class.new
    expect(alert).to receive(:user).and_return(instance_double(Account, name: "dummy-name", email: "dummy-email")).at_least(:once)
    expect(alert).to receive(:project).and_return(instance_double(Project, name: "dummy-name", ubid: "dummy-ubid", path: "dummy-path", current_invoice: instance_double(Invoice, content: {"cost" => "dummy-cost"}))).at_least(:once)
    expect(Util).to receive(:send_email)
    expect(Time).to receive(:now).and_return("dummy-time")
    expect(alert).to receive(:update).with(last_triggered_at: "dummy-time")
    alert.trigger
  end
end
