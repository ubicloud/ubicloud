# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/gcp_database_auth"

RSpec.describe GcpDatabaseAuth do
  # Stub the real GCP IAM Credentials boundary instead of any test seam in the
  # module itself. The google gems are required lazily inside mint_impersonated,
  # so these classes load AFTER Refrigerator.freeze_core and remain unfrozen —
  # which is what lets RSpec stub them even in frozen tests. The block receives
  # the resource path ("projects/-/serviceAccounts/<sa-email>") and returns the
  # token string the API should hand back.
  def stub_iam_credentials(expire_time: (Time.now + 3600).utc.iso8601)
    require "googleauth"
    require "google/apis/iamcredentials_v1"
    svc = instance_double(Google::Apis::IamcredentialsV1::IAMCredentialsService)
    allow(svc).to receive(:authorization=)
    allow(svc).to receive(:generate_service_account_access_token) do |resource, _req|
      Struct.new(:access_token, :expire_time).new(yield(resource), expire_time)
    end
    allow(Google::Apis::IamcredentialsV1::IAMCredentialsService).to receive(:new).and_return(svc)
    allow(Google::Auth).to receive(:get_application_default).and_return(Object.new)
    svc
  end

  describe ".db_user_for" do
    it "strips the gserviceaccount.com suffix to yield the IAM db username" do
      expect(described_class.db_user_for("clover-sa@my-project.iam.gserviceaccount.com"))
        .to eq("clover-sa@my-project.iam")
    end

    it "leaves a bare db username unchanged" do
      expect(described_class.db_user_for("clover-sa@my-project.iam")).to eq("clover-sa@my-project.iam")
    end
  end

  describe ".url_user" do
    it "extracts the userinfo from a connection URL" do
      expect(described_class.url_user("postgres://clover@10.0.0.5/clover?sslmode=require")).to eq("clover")
    end

    it "percent-decodes the user, matching Sequel" do
      expect(described_class.url_user("postgres://clover-sa%40p.iam@h/db")).to eq("clover-sa@p.iam")
    end

    it "reads the role from a ?user= query parameter (Clover's standard URL form)" do
      expect(described_class.url_user("postgres:///clover_test?user=clover")).to eq("clover")
    end

    it "lets a ?user= query parameter override userinfo (matches Sequel)" do
      expect(described_class.url_user("postgres://ignored@h/db?user=clover")).to eq("clover")
    end

    it "returns nil when the URL carries no user" do
      expect(described_class.url_user("postgres://h/clover")).to be_nil
    end
  end

  describe ".role_connect_option" do
    it "nil for blank, string otherwise, rejects junk" do
      expect(described_class.role_connect_option(nil)).to be_nil
      expect(described_class.role_connect_option("")).to be_nil
      expect(described_class.role_connect_option("clover")).to eq("-c role=clover")
      expect { described_class.role_connect_option("a; DROP") }.to raise_error(ArgumentError)
    end
  end

  describe ".access_token" do
    before { described_class.reset_cache! }

    it "mints by impersonation, targeting the given SA" do
      svc = stub_iam_credentials { |_resource| "real-token" }
      expect(described_class.access_token(service_account: "clover-sa@my-project.iam.gserviceaccount.com")).to eq("real-token")
      expect(svc).to have_received(:generate_service_account_access_token)
        .with("projects/-/serviceAccounts/clover-sa@my-project.iam.gserviceaccount.com", anything)
    end

    it "surfaces the SA and body, preserving the original backtrace, when generateAccessToken is rejected" do
      require "googleauth"
      require "google/apis/iamcredentials_v1"
      svc = instance_double(Google::Apis::IamcredentialsV1::IAMCredentialsService)
      allow(svc).to receive(:authorization=)
      allow(svc).to receive(:generate_service_account_access_token)
        .and_raise(Google::Apis::ClientError.new("Invalid request", body: '{"error":{"status":"INVALID_ARGUMENT"}}'))
      allow(Google::Apis::IamcredentialsV1::IAMCredentialsService).to receive(:new).and_return(svc)
      allow(Google::Auth).to receive(:get_application_default).and_return(Object.new)

      expect { described_class.access_token(service_account: "clover-sa@my-project.iam.gserviceaccount.com") }
        .to raise_error(Google::Apis::ClientError, /clover-sa@my-project\.iam\.gserviceaccount\.com.*INVALID_ARGUMENT/m) do |error|
          expect(error.backtrace).to eq(error.cause.backtrace) # original backtrace kept, not reset to the rescue line
        end
    end

    it "caches a minted token per SA and reuses it until near expiry" do
      calls = 0
      stub_iam_credentials { |_resource| "tok-#{calls += 1}" }
      t1 = described_class.access_token(service_account: "clover-sa@my-project.iam.gserviceaccount.com")
      t2 = described_class.access_token(service_account: "clover-sa@my-project.iam.gserviceaccount.com")
      expect([t1, t2, calls]).to eq(["tok-1", "tok-1", 1])
    end

    it "derives the cache lifetime from the response's expire_time (not a fixed 3600)" do
      calls = 0
      # expire_time inside the 5-minute refresh buffer => the second call must
      # re-mint; a hardcoded 3600 lifetime would wrongly reuse the first token.
      stub_iam_credentials(expire_time: (Time.now + 30).utc.iso8601) { |_resource| "tok-#{calls += 1}" }
      service_account = "clover-sa@my-project.iam.gserviceaccount.com"
      described_class.access_token(service_account:)
      described_class.access_token(service_account:)
      expect(calls).to eq(2)
    end

    it "keys the cache by SA (each SA gets its own token)" do
      stub_iam_credentials { |resource| "tok:#{resource}" }
      a = described_class.access_token(service_account: "clover-sa@my-project.iam.gserviceaccount.com")
      b = described_class.access_token(service_account: "clover-sa-ph@my-project.iam.gserviceaccount.com")
      expect(a).not_to eq(b)
    end

    # Stubs the (lazily-loaded, unfrozen) IAM client rather than GcpDatabaseAuth
    # itself, so it also runs under frozen tests where the module can't be stubbed.
    it "re-checks under the per-SA lock so a concurrent fetch reuses the token instead of minting twice" do
      require "googleauth"
      require "google/apis/iamcredentials_v1"
      service_account = "clover-sa@my-project.iam.gserviceaccount.com"
      proceed = Queue.new
      mints = 0
      svc = instance_double(Google::Apis::IamcredentialsV1::IAMCredentialsService)
      allow(svc).to receive(:authorization=)
      allow(svc).to receive(:generate_service_account_access_token) do
        mints += 1
        proceed.pop if mints == 1 # hold the per-SA lock until the second caller is waiting
        Struct.new(:access_token, :expire_time).new("tok-#{mints}", (Time.now + 3600).utc.iso8601)
      end
      allow(Google::Apis::IamcredentialsV1::IAMCredentialsService).to receive(:new).and_return(svc)
      allow(Google::Auth).to receive(:get_application_default).and_return(Object.new)

      first = Thread.new { described_class.access_token(service_account:) }
      Thread.pass until mints == 1               # first holds the per-SA lock, inside the blocked mint
      second = Thread.new { described_class.access_token(service_account:) }
      Thread.pass until second.status == "sleep" # second passed the fast path, now blocked on the lock
      proceed << :go                             # let first finish minting and cache the token

      expect([first.value, second.value, mints]).to eq(["tok-1", "tok-1", 1])
    end
  end

  describe GcpDatabaseAuth::ServerOptsInjection do
    before { GcpDatabaseAuth.reset_cache! }

    let(:sa) { "clover-sa@my-project.iam.gserviceaccount.com" }
    let(:map) { {"clover" => sa} }

    # Build a throwaway Database-like class whose #server_opts returns the given
    # hash, then prepend the injection and call through it.
    def hooked(server_opts_hash)
      klass = Class.new do
        define_method(:server_opts) { |_server| server_opts_hash }
      end
      klass.prepend(GcpDatabaseAuth::ServerOptsInjection)
      klass.new.server_opts(nil)
    end

    it "injects the token + login user + role option for a mapped role, stripping the marker" do
      stub_iam_credentials { |_resource| "minted-token" }
      out = hooked(user: "clover", driver_options: {gcp_cloudsql_iam_sa_by_role: map})
      expect(out[:user]).to eq("clover-sa@my-project.iam")
      expect(out[:password]).to eq("minted-token")
      expect(out[:driver_options][:options]).to eq("-c role=clover")
      expect(out[:driver_options]).not_to have_key(:gcp_cloudsql_iam_sa_by_role)
    end

    it "raises a GcpDatabaseAuth::Error for a role not in the map" do
      expect { hooked(user: "nope", driver_options: {gcp_cloudsql_iam_sa_by_role: map}) }
        .to raise_error(GcpDatabaseAuth::Error, /no CloudSQL IAM SA mapped for role "nope"/)
    end

    it "passes opts through untouched when the marker is absent (customer DBs / legacy)" do
      expect(hooked(user: "u")).to eq(user: "u")
    end

    it "does not mutate the caller's driver_options hash" do
      stub_iam_credentials { |_resource| "minted-token" }
      driver_options = {gcp_cloudsql_iam_sa_by_role: map}
      hooked(user: "clover", driver_options:)
      expect(driver_options).to eq(gcp_cloudsql_iam_sa_by_role: map)
    end
  end
end
