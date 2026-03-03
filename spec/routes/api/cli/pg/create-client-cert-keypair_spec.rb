# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg create-client-cert-keypair" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    @pg = PostgresResource.first
    @pg.root_cert_1, @pg.root_cert_key_1 = Util.create_root_certificate(common_name: "#{@pg.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
    @pg.root_cert_2, @pg.root_cert_key_2 = Util.create_root_certificate(common_name: "#{@pg.ubid} Root Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
    @pg.client_root_cert_1, @pg.client_root_cert_key_1 = Util.create_root_certificate(common_name: "#{@pg.ubid} Client Certificate Authority", duration: 60 * 60 * 24 * 365 * 5)
    @pg.client_root_cert_2, @pg.client_root_cert_key_2 = Util.create_root_certificate(common_name: "#{@pg.ubid} Client Certificate Authority", duration: 60 * 60 * 24 * 365 * 10)
    @pg.save_changes
  end

  it "creates and returns a client certificate keypair" do
    result = cli(%w[pg eu-central-h1/test-pg create-client-cert-keypair myuser 3600])
    cert = OpenSSL::X509::Certificate.new(result)
    expect(cert.subject.to_s).to eq("/C=US/O=None/CN=myuser")
  end
end
