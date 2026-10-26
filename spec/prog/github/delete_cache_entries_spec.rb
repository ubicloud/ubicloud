# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::DeleteCacheEntries do
  let(:repository) { GithubRepository.create(name: "test") }

  let(:dce) { described_class.new(described_class.assemble(repository.id)) }

  let(:entries) {
    Array.new(2) do
      repository.add_cache_entry(
        key: "k#{it}",
        version: "v#{it}",
        scope: "main",
        upload_id: "upload-#{it}",
        created_by: "3c9a861c-ab14-8218-a175-875ebb652f7b",
        created_at: Time.now - 2 + it,
      )
    end
  }

  describe ".assemble" do
    it "creates a strand" do
      st = described_class.assemble(repository.id)
      expect(st.prog).to eq "Github::DeleteCacheEntries"
      expect(st.label).to eq "delete_entries"
      expect(st.stack[0]["subject_id"]).to eq repository.id
      expect(Time.new(st.stack[0]["initiated_at"])).to be_within(10).of(Time.now)
    end

    it "accepts an initiated_at Time" do
      initiated_at = Time.utc(2025, 11, 12, 13, 14, 15)
      st = described_class.assemble(repository.id, initiated_at:)
      expect(st.prog).to eq "Github::DeleteCacheEntries"
      expect(st.label).to eq "delete_entries"
      expect(st.stack[0]["subject_id"]).to eq repository.id
      expect(Time.new(st.stack[0]["initiated_at"])).to eq initiated_at
    end
  end

  describe "#delete_entries" do
    let(:client) { instance_double(Aws::S3::Client) }

    before { allow(Aws::S3::Client).to receive(:new).and_return(client) }

    it "deletes cache entry and naps until no cache entries are left" do
      entries = self.entries
      entries.each do |entry|
        expect(client).to receive(:abort_multipart_upload).with(bucket: repository.bucket_name, key: entry.blob_key, upload_id: entry.upload_id)
        expect(client).to receive(:delete_object).with(bucket: repository.bucket_name, key: entry.blob_key)
      end

      expect { dce.delete_entries }.to nap(0)
      expect(entries[0]).not_to exist
      expect(entries[1]).to exist

      expect { dce.delete_entries }.to nap(0)
      expect(entries[0]).not_to exist
      expect(entries[1]).not_to exist

      expect { dce.delete_entries }.to exit({"msg" => "all cache entries deleted"})
    end

    it "deletes blob storage outside of the transaction and destroys the cache entry inside the transaction" do
      entry = entries[0]
      st = described_class.assemble(repository.id)
      in_transaction = false
      allow(DB).to receive(:transaction).and_wrap_original do |m, *args, **kwargs, &block|
        if kwargs == {savepoint: true}
          begin
            in_transaction = true
            m.call(*args, **kwargs, &block)
          ensure
            in_transaction = false
          end
        else
          m.call(*args, **kwargs, &block)
        end
      end
      expect(client).to receive(:abort_multipart_upload) do
        expect(in_transaction).to be false
      end
      expect(client).to receive(:delete_object) do
        expect(in_transaction).to be false
      end
      expect(DeletedRecord).to receive(:create).and_wrap_original do |m, **kwargs|
        expect(in_transaction).to be true
        m.call(**kwargs)
      end
      expect(st.unsynchronized_run).to be_a Prog::Base::Nap
      expect(entry).not_to exist
    end
  end

  describe "#next_entry" do
    it "returns next entry when using a time-based deletion" do
      entries = self.entries
      expect(dce.next_entry).to eq entries[0]
      entries[0].this.update(created_at: Time.now + 10)
      expect(dce.next_entry).to eq entries[1]
      entries[1].this.update(created_at: Time.now + 10)
      expect(dce.next_entry).to be_nil
    end

    it "returns next entry when deleting specific ids" do
      cache_entry_ids = entries.map(&:id)
      dce = described_class.new(described_class.assemble(repository.id, cache_entry_ids:))
      returned_cache_entry_ids = []
      returned_cache_entry_ids << dce.next_entry.id
      expect(dce.strand.stack[0]["cache_entry_ids"].size).to eq 1
      returned_cache_entry_ids << dce.next_entry.id
      expect(cache_entry_ids.sort).to eq returned_cache_entry_ids.sort
      expect(dce.strand.stack[0]["cache_entry_ids"]).to eq []
      expect(dce.next_entry).to be_nil
    end

    it "returns nil if no github repository" do
      repository.destroy
      expect(dce.next_entry).to be_nil
    end
  end
end
