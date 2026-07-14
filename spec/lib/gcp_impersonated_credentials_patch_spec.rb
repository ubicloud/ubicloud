# frozen_string_literal: true

require_relative "../../lib/gcp_impersonated_credentials_patch"

RSpec.describe GcpImpersonatedCredentialsPatch do
  it "returns the auth header populated by the source's (non-mutating) updater_proc" do
    # Mimic Google::Auth::BaseClient#updater_proc: non-mutating — it returns a populated
    # COPY and leaves the passed hash empty. The unpatched gem returned that still-empty
    # hash (-> 401 CREDENTIALS_MISSING); the patch returns updater_proc.call's result.
    source = Object.new
    source.define_singleton_method(:updater_proc) do
      ->(hash, _opts = {}) { hash.merge(authorization: "Bearer test-token") }
    end

    creds = Google::Auth::ImpersonatedServiceAccountCredentials.make_creds(
      source_credentials: source,
      impersonation_url: "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/sa@proj.iam.gserviceaccount.com:generateAccessToken",
      scope: ["https://www.googleapis.com/auth/cloud-platform"],
    )

    expect(creds.send(:prepare_auth_header)).to eq(authorization: "Bearer test-token")
  end
end
