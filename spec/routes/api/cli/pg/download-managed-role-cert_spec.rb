# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg download-managed-role-cert" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
    @pg.client_root_cert_1, @pg.client_root_cert_key_1 = Util.create_root_certificate(common_name: "#{@pg.ubid} CA", duration: 60 * 60 * 24 * 365 * 5)
    @pg.client_root_cert_2, @pg.client_root_cert_key_2 = Util.create_root_certificate(common_name: "#{@pg.ubid} CA", duration: 60 * 60 * 24 * 365 * 10)
    @pg.save_changes
  end

  it "downloads the certificate bundle for a cert-auth managed role" do
    role = PostgresManagedRole.create(postgres_resource_id: @pg.id, name: "app_rw", auth_type: "cert", state: "active")
    role.issue_certificate!

    output = cli(%w[pg eu-central-h1/test-pg download-managed-role-cert app_rw])
    expect(output).to include("BEGIN CERTIFICATE")
    expect(output).to include("PRIVATE KEY")
  end

  it "errors when the managed role does not exist" do
    expect(cli(%w[pg eu-central-h1/test-pg download-managed-role-cert nope], status: 400)).to start_with "! No managed role named nope\n"
  end

  it "errors when the managed role has no certificate" do
    PostgresManagedRole.create(postgres_resource_id: @pg.id, name: "app_pw", auth_type: "password", state: "active")
    expect(cli(%w[pg eu-central-h1/test-pg download-managed-role-cert app_pw], status: 400)).to start_with "! Managed role app_pw has no certificate to download\n"
  end
end
