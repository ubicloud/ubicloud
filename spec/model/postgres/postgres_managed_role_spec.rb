# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresManagedRole do
  let(:project) { Project.create(name: "pg-test-project") }
  let(:postgres_resource) {
    PostgresResource.create(
      name: "pg-name",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id: Location::HETZNER_FSN1_ID,
      project_id: project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    )
  }

  def create_role(name: "app_rw", auth_type: "cert", **)
    PostgresManagedRole.create(postgres_resource_id: postgres_resource.id, name:, auth_type:, **)
  end

  it "creates a cert-auth role in the creating state by default" do
    role = create_role
    expect(role.cert_auth?).to be(true)
    expect(role.state).to eq("creating")
  end

  it "creates a password-auth role" do
    expect(create_role(auth_type: "password").cert_auth?).to be(false)
  end

  it "rejects an invalid auth_type" do
    expect { create_role(auth_type: "ldap") }.to raise_error(Sequel::ValidationFailed)
  end

  it "rejects reserved role names" do
    PostgresManagedRole::RESERVED_NAMES.each do |reserved|
      expect { create_role(name: reserved) }.to raise_error(Sequel::ValidationFailed, /reserved/)
    end
  end

  it "rejects pg_-prefixed role names" do
    expect { create_role(name: "pg_stat") }.to raise_error(Sequel::ValidationFailed, /reserved/)
  end

  it "rejects names with invalid format" do
    expect { create_role(name: "Bad-Name") }.to raise_error(Sequel::ValidationFailed, /name/)
    expect { create_role(name: "1role") }.to raise_error(Sequel::ValidationFailed, /name/)
  end

  it "rejects names longer than 63 characters" do
    expect { create_role(name: "a" * 64) }.to raise_error(Sequel::ValidationFailed, /name/)
  end

  it "enforces unique role name per resource" do
    create_role(name: "dup")
    expect { create_role(name: "dup") }.to raise_error(Sequel::ValidationFailed, /already taken/)
  end

  it "has no certificate bundle before a certificate is issued" do
    expect(create_role.certificate_bundle).to be_nil
  end

  describe "#issue_certificate!" do
    before do
      root_cert, root_key = Util.create_root_certificate(common_name: "Ubicloud Client CA", duration: 60 * 60 * 24 * 365 * 5)
      postgres_resource.update(client_root_cert_1: root_cert, client_root_cert_key_1: root_key)
    end

    it "signs and stores a client certificate with the role name as CN" do
      role = create_role
      role.issue_certificate!

      cert = OpenSSL::X509::Certificate.new(role.cert)
      expect(cert.subject.to_s).to include("CN=app_rw")
      expect(cert.extensions.map(&:to_s).join).to include("TLS Web Client Authentication")
      expect(role.cert_not_after).to be_within(5).of(cert.not_after)
      expect { OpenSSL::PKey::EC.new(role.cert_key) }.not_to raise_error
      expect(role.certificate_bundle).to eq("#{role.cert}#{role.cert_key}")
    end
  end

  describe "PostgresResource#managed_cert_roles" do
    it "returns active/creating cert role names, excluding password and destroying roles" do
      create_role(name: "cert_a", auth_type: "cert", state: "active")
      create_role(name: "cert_b", auth_type: "cert", state: "creating")
      create_role(name: "pw_role", auth_type: "password", state: "active")
      create_role(name: "gone", auth_type: "cert", state: "destroying")
      expect(postgres_resource.managed_cert_roles.sort).to eq(["cert_a", "cert_b"])
    end
  end
end
