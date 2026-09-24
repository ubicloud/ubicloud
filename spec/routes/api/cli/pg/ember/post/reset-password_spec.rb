# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Clover, "cli pg ember reset-password" do
  it "reports the new password, which it generates itself" do
    ember = create_postgres_ember(project_id: @project.id, name: "one", state: "paused")
    was = ember.superuser_password
    body = cli(%w[pg ember one reset-password])
    expect(ember.reload.superuser_password).not_to eq(was)
    expect(body).to eq("password: #{ember.superuser_password}\n")
  end
end
