# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubConnectRequest do
  let(:project) { Project.create(name: "test-project") }

  it "deletes expired requests when a new request starts" do
    expired = described_class.start(project.id)
    expired.this.update(created_at: Time.now - 10 * 60 - 1)
    active = described_class.start(project.id)

    expect(described_class.select_order_map(:id)).to eq [active.id]
  end

  it "expires the code 10 minutes after the request starts" do
    request = described_class.start(project.id)
    request.this.update(created_at: Time.now - 9 * 60)
    code = request.set_code(123)
    expect(described_class.with_code(project.id, code).installation_id).to eq 123

    expect(Time).to receive(:now).and_return(Time.now + 61).at_least(:once)
    expect(described_class.with_code(project.id, code)).to be_nil
  end
end
