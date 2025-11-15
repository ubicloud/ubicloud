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
        created_at: Time.now - 2 + it
      )
    end
  }

  describe ".assemble" do
    it "creates a strand" do
      st = described_class.assemble(repository.id)
      expect(st.prog).to eq "Github::DeleteCacheEntries"
      expect(st.label).to eq "delete_entries"
      expect(st.stack[0]["subject_id"]).to eq repository.id
      expect(Time.parse(st.stack[0]["initiated_at"])).to be_within(10).of(Time.now)
    end

    it "accepts an initiated_at Time" do
      initiated_at = Time.utc(2025, 11, 12, 13, 14, 15)
      st = described_class.assemble(repository.id, initiated_at:)
      expect(st.prog).to eq "Github::DeleteCacheEntries"
      expect(st.label).to eq "delete_entries"
      expect(st.stack[0]["subject_id"]).to eq repository.id
      expect(Time.parse(st.stack[0]["initiated_at"])).to eq initiated_at
    end
  end

  describe "#delete_entries" do
    it "deletes cache entry and naps until no cache entries are left" do
      entries = self.entries
      next_entries = entries.dup
      dce.define_singleton_method(:next_entry) { next_entries.shift }
      entries.each { it.define_singleton_method(:after_destroy) {} }

      expect { dce.delete_entries }.to nap(0)
      expect(entries[0]).not_to exist
      expect(entries[1]).to exist

      expect { dce.delete_entries }.to nap(0)
      expect(entries[0]).not_to exist
      expect(entries[1]).not_to exist

      expect { dce.delete_entries }.to exit({"msg" => "all cache entries deleted"})
    end
  end

  describe "#next_entry" do
    it "returns next entry" do
      entries = self.entries
      expect(dce.next_entry).to eq entries[0]
      entries[0].this.update(created_at: Time.now + 10)
      expect(dce.next_entry).to eq entries[1]
      entries[1].this.update(created_at: Time.now + 10)
      expect(dce.next_entry).to be_nil
    end
  end
end
