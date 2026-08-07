# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/gcp_database_auth"
require "googleauth"
require "google/apis/iamcredentials_v1"

RSpec.describe GcpDatabaseAuth do
  # Stub the real GCP IAM Credentials boundary instead of any test seam in the
  # module itself. The lib (and with it the google gems) is only loaded by
  # db.rb's GCP branch, never at app boot, so these classes load AFTER
  # Refrigerator.freeze_core and remain unfrozen — which is what lets RSpec
  # stub them even in frozen tests. The block receives the resource path
  # ("projects/-/serviceAccounts/<sa-email>") and returns the token string the
  # API should hand back.
  def stub_iam_credentials(expire_time: (Time.now + 3600).utc.iso8601)
    adc = Object.new
    svc = instance_double(Google::Apis::IamcredentialsV1::IAMCredentialsService)
    allow(svc).to receive(:authorization=).with(adc)
    allow(svc).to receive(:generate_service_account_access_token) do |resource, _req|
      Struct.new(:access_token, :expire_time).new(yield(resource), expire_time)
    end
    allow(Google::Apis::IamcredentialsV1::IAMCredentialsService).to receive(:new).with(no_args).and_return(svc)
    allow(Google::Auth).to receive(:get_application_default).with(["https://www.googleapis.com/auth/cloud-platform"]).and_return(adc)
    svc
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

  describe ".connect_opts_proc" do
    before { described_class.send(:reset_cache!) }

    let(:sa) { "clover-sa@my-project.iam.gserviceaccount.com" }
    let(:opts_proc) { described_class.connect_opts_proc({"clover" => sa}) }

    def call_proc(opts_proc, user: "clover")
      opts = {user:, driver_options: {}}
      opts_proc.call(opts)
      opts
    end

    it "rewrites opts with the SA login user (email minus its .gserviceaccount.com suffix), minted-token password, and role option" do
      stub_iam_credentials { |_resource| "minted-token" }
      opts = call_proc(opts_proc)
      expect(opts[:user]).to eq("clover-sa@my-project.iam")
      expect(opts[:password]).to eq("minted-token")
      expect(opts[:driver_options][:options]).to eq("-c role=clover")
    end

    it "leaves a bare SA db username (no suffix) unchanged" do
      stub_iam_credentials { |_resource| "minted-token" }
      opts_proc = described_class.connect_opts_proc({"clover" => "clover-sa@my-project.iam"})
      expect(call_proc(opts_proc)[:user]).to eq("clover-sa@my-project.iam")
    end

    it "raises a GcpDatabaseAuth::Error for a role not in the map" do
      expect { opts_proc.call({user: "nope", driver_options: {}}) }
        .to raise_error(GcpDatabaseAuth::Error, /no CloudSQL IAM SA mapped for role "nope"/)
    end

    it "sets no role option when the mapped role is blank" do
      stub_iam_credentials { |_resource| "minted-token" }
      opts_proc = described_class.connect_opts_proc({nil => sa, "" => sa})
      expect(call_proc(opts_proc, user: nil)[:driver_options][:options]).to be_nil
      expect(call_proc(opts_proc, user: "")[:driver_options][:options]).to be_nil
    end

    it "rejects a role that is not a bare identifier (fail-closed)" do
      stub_iam_credentials { |_resource| "minted-token" }
      opts_proc = described_class.connect_opts_proc({"a; DROP" => sa})
      expect { call_proc(opts_proc, user: "a; DROP") }.to raise_error(ArgumentError, /invalid role identifier/)
    end

    it "does not mutate the caller's existing driver_options hash" do
      stub_iam_credentials { |_resource| "minted-token" }
      driver_options = {}
      opts_proc.call({user: "clover", driver_options:})
      expect(driver_options).to eq({})
    end

    it "mints by impersonation, targeting the mapped SA" do
      svc = stub_iam_credentials { |_resource| "minted-token" }
      call_proc(opts_proc)
      expect(svc).to have_received(:generate_service_account_access_token)
        .with("projects/-/serviceAccounts/clover-sa@my-project.iam.gserviceaccount.com", anything)
    end

    it "surfaces the SA and body, preserving the original backtrace, when generateAccessToken is rejected" do
      adc = Object.new
      svc = instance_double(Google::Apis::IamcredentialsV1::IAMCredentialsService)
      allow(svc).to receive(:authorization=).with(adc)
      allow(svc).to receive(:generate_service_account_access_token)
        .with("projects/-/serviceAccounts/#{sa}", anything)
        .and_raise(Google::Apis::ClientError.new("Invalid request", body: '{"error":{"status":"INVALID_ARGUMENT"}}'))
      allow(Google::Apis::IamcredentialsV1::IAMCredentialsService).to receive(:new).with(no_args).and_return(svc)
      allow(Google::Auth).to receive(:get_application_default).with(["https://www.googleapis.com/auth/cloud-platform"]).and_return(adc)

      expect { call_proc(opts_proc) }
        .to raise_error(Google::Apis::ClientError, /clover-sa@my-project\.iam\.gserviceaccount\.com.*INVALID_ARGUMENT/m) do |error|
          expect(error.backtrace).to eq(error.cause.backtrace) # original backtrace kept, not reset to the rescue line
        end
    end

    it "caches a minted token per SA and reuses it until near expiry" do
      calls = 0
      stub_iam_credentials { |_resource| "tok-#{calls += 1}" }
      t1 = call_proc(opts_proc)[:password]
      t2 = call_proc(opts_proc)[:password]
      expect([t1, t2, calls]).to eq(["tok-1", "tok-1", 1])
    end

    it "derives the cache lifetime from the response's expire_time (not a fixed 3600)" do
      calls = 0
      # expire_time inside the 5-minute refresh buffer => the second call must
      # re-mint; a hardcoded 3600 lifetime would wrongly reuse the first token.
      stub_iam_credentials(expire_time: (Time.now + 30).utc.iso8601) { |_resource| "tok-#{calls += 1}" }
      call_proc(opts_proc)
      call_proc(opts_proc)
      expect(calls).to eq(2)
    end

    it "keys the cache by SA (each SA gets its own token)" do
      stub_iam_credentials { |resource| "tok:#{resource}" }
      opts_proc = described_class.connect_opts_proc({
        "clover" => sa,
        "clover_password" => "clover-sa-ph@my-project.iam.gserviceaccount.com",
      })
      a = call_proc(opts_proc)[:password]
      b = call_proc(opts_proc, user: "clover_password")[:password]
      expect(a).not_to eq(b)
    end

    # Stubs the (unfrozen) IAM client rather than GcpDatabaseAuth itself, so it
    # also runs under frozen tests where the module can't be stubbed.
    it "holds the lock while minting so a concurrent fetch reuses the token instead of minting twice" do
      proceed = Queue.new
      mints = 0
      adc = Object.new
      svc = instance_double(Google::Apis::IamcredentialsV1::IAMCredentialsService)
      allow(svc).to receive(:authorization=).with(adc)
      allow(svc).to receive(:generate_service_account_access_token) do
        mints += 1
        proceed.pop if mints == 1 # hold the lock until the second caller is waiting
        Struct.new(:access_token, :expire_time).new("tok-#{mints}", (Time.now + 3600).utc.iso8601)
      end
      allow(Google::Apis::IamcredentialsV1::IAMCredentialsService).to receive(:new).with(no_args).and_return(svc)
      allow(Google::Auth).to receive(:get_application_default).with(["https://www.googleapis.com/auth/cloud-platform"]).and_return(adc)

      first = Thread.new { call_proc(opts_proc)[:password] }
      Thread.pass until mints == 1               # first holds the lock, inside the blocked mint
      second = Thread.new { call_proc(opts_proc)[:password] }
      Thread.pass until second.status == "sleep" # second is blocked on the lock
      proceed << :go                             # let first finish minting and cache the token

      expect([first.value, second.value, mints]).to eq(["tok-1", "tok-1", 1])
    end
  end
end
