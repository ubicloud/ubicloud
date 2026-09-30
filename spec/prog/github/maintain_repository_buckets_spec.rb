# frozen_string_literal: true

require "aws-sdk-s3"
require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::MaintainRepositoryBuckets do
  subject(:prog) { described_class.new(st) }

  let(:st) {
    Strand.create(
      id: described_class::STRAND_ID,
      prog: "Github::MaintainRepositoryBuckets",
      label: "wait",
      stack: [{"last_bucket_created" => Time.now.to_i - 70}],
    )
  }

  describe ".schedule_strand" do
    it "schedules the strand if it is in wait" do
      st.update(schedule: Time.now + 60 * 60)
      described_class.schedule_strand
      expect(st.reload.schedule).to be <= Time.now
    end

    it "does not schedule the strand if it is not in wait" do
      st.update(label: "create_bucket", schedule: Time.now + 60 * 60)
      described_class.schedule_strand
      expect(st.reload.schedule).to be > Time.now
    end
  end

  describe "#wait" do
    it "naps if last bucket was created too recently" do
      refresh_frame(prog, new_values: {"last_bucket_created" => Time.now.to_i - 5})
      expect { prog.wait }.to nap(1..5)
    end

    it "naps if sufficient buckets have been created" do
      20.times { GithubRepositoryBucket.create(access_key: "ak-#{it}", secret_key: "sk-#{it}") }
      expect { prog.wait }.to nap(60 * 60)
    end

    it "registers deadline and hops if sufficient buckets have not been created" do
      19.times { GithubRepositoryBucket.create(access_key: "ak-#{it}", secret_key: "sk-#{it}") }
      expect { prog.wait }.to hop("create_bucket")
      frame = prog.strand.stack[0]
      expect(frame["deadline_target"]).to eq "wait"
      expect(Time.new(frame["deadline_at"])).to be_within(5).of(Time.now + 5 * 60)
    end
  end

  describe "#create_bucket" do
    it "creates a bucket and token, records them, and hops to wait" do
      expect(Config).to receive_messages(github_cache_blob_storage_region: "weur", github_cache_blob_storage_account_id: "123")
      blob_storage_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
      bucket_name = nil
      expect(blob_storage_client).to receive(:create_bucket) do |args|
        bucket_name = args[:bucket]
        expect(args).to eq({bucket: bucket_name, create_bucket_configuration: {location_constraint: "weur"}})
      end
      cloudflare_client = instance_double(CloudflareClient)
      expect(CloudflareClient).to receive(:new).and_return(cloudflare_client)
      expect(cloudflare_client).to receive(:create_token) do |name, policies|
        expect(name).to eq "#{bucket_name}-token"
        expect(policies).to eq [
          {
            "effect" => "allow",
            "permission_groups" => [{"id" => "2efd5506f9c8494dacb1fa10a3e7d5b6", "name" => "Workers R2 Storage Bucket Item Write"}],
            "resources" => {"com.cloudflare.edge.r2.bucket.123_default_#{bucket_name}" => "*"},
          },
        ]
        ["test-key", "test-secret"]
      end
      refresh_frame(prog, new_values: {"last_bucket_created" => 0})

      expect { prog.create_bucket }.to hop("wait")
        .and change(GithubRepositoryBucket, :count).from(0).to(1)

      bucket = GithubRepositoryBucket.first
      expect(bucket.ubid).to eq bucket_name
      expect(bucket_name).to start_with("et")
      expect(bucket.access_key).to eq "test-key"
      expect(bucket.secret_key).to eq Digest::SHA256.hexdigest("test-secret")
      expect(prog.strand.stack[0]["last_bucket_created"]).to be_within(5).of(Time.now.to_i)
    end

    it "raises without creating a token if the bucket already exists" do
      blob_storage_client = instance_double(Aws::S3::Client)
      expect(Aws::S3::Client).to receive(:new).and_return(blob_storage_client)
      expect(blob_storage_client).to receive(:create_bucket).and_raise(Aws::S3::Errors::BucketAlreadyOwnedByYou.new(nil, nil))
      expect(CloudflareClient).not_to receive(:new)

      expect { prog.create_bucket }.to raise_error(Aws::S3::Errors::BucketAlreadyOwnedByYou)
      expect(GithubRepositoryBucket.count).to eq 0
    end
  end
end
