# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/gcp_database_auth"

# This file groups config defaults, db.rb wiring guards, and the rake-task-runner
# ph-bootstrap guard — distinct subjects, so multiple top-level describes (all
# prose, not a class) are intentional.
# rubocop:disable RSpec/MultipleDescribes, RSpec/DescribeClass
RSpec.describe "CloudSQL IAM config defaults" do
  it "defaults to disabled/nil (current behavior preserved)" do
    expect(Config.clover_database_gcp_iam_auth_enabled).to be(false)
    expect(Config.clover_database_gcp_clover_login_sa).to be_nil
    expect(Config.clover_database_gcp_clover_password_login_sa).to be_nil
  end
end

RSpec.describe "db.rb wiring" do
  let(:src) { File.read(File.expand_path("../db.rb", __dir__)) }

  it "loads GcpDatabaseAuth only on the gcp-enabled path (require sits inside the branch)" do
    expect(src).to match(/elsif Config\.clover_database_gcp_iam_auth_enabled\n\s+require_relative "lib\/gcp_database_auth"/)
  end

  it "builds the role->sa map in driver_options from the URL user and the two SA configs" do
    expect(src).to include("gcp_cloudsql_iam_sa_by_role")
    expect(src).to include("GcpDatabaseAuth.url_user(Config.clover_database_url)")
    expect(src).to include("Config.clover_database_gcp_clover_login_sa")
    expect(src).to include("Config.clover_database_gcp_clover_password_login_sa")
  end

  it "no longer uses the removed builders or after_connect" do
    expect(src).not_to include("gcp_connection_opts")
    expect(src).not_to include("ph_connection_opts")
    expect(src).not_to include("after_connect")
  end
end

RSpec.describe "rake-task-runner ph bootstrap" do
  let(:src) { File.read(File.expand_path("../bin/rake-task-runner", __dir__)) }

  it "reconnects as the derived ph role (upstream form) with no GcpDatabaseAuth reference" do
    expect(src).to include("Sequel.postgres(**DB.opts, user: ph_user)")
    expect(src).not_to include("GcpDatabaseAuth")
    expect(src).not_to include("ph_connection_opts")
  end
end
# rubocop:enable RSpec/MultipleDescribes, RSpec/DescribeClass
