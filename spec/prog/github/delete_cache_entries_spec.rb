# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Github::DeleteCacheEntries do
  subject(:dce) {
    described_class.new(Strand.new(id: repository.id)).tap {
      it.instance_variable_set(:@github_repository, repository)
    }
  }

  let(:repository) { instance_double(GithubRepository, id: "a58006b6-0879-8616-936a-62234e244f2f") }

  describe ".assemble" do
    it "creates a strand" do
      expect(Strand).to receive(:create_with_id).with(
        repository.id,
        prog: "Github::DeleteCacheEntries",
        label: "start",
        stack: [{
          "subject_id" => repository.id,
          "initiated_at" => kind_of(String)
        }]
      )
      described_class.assemble(repository.id)
    end

    it "accepts a Time instance" do
      time = Time.now
      expect(Strand).to receive(:create_with_id).with(
        repository.id,
        prog: "Github::DeleteCacheEntries",
        label: "start",
        stack: [{
          "subject_id" => repository.id,
          "initiated_at" => time.to_s
        }]
      )
      described_class.assemble(repository.id, time)
    end
  end

  describe "#start" do
    it "hops to delete_entries" do
      expect { dce.start }.to hop("delete_entries")
    end
  end

  describe "#delete_entries" do
    it "deletes cache entry and naps" do
      cache_entry = instance_double(GithubCacheEntry)
      cache_entries_dataset = instance_double(Sequel::Dataset)
      expect(repository).to receive(:cache_entries_dataset).and_return(cache_entries_dataset)
      expect(cache_entries_dataset).to receive(:first).and_return(cache_entry)
      expect(cache_entry).to receive(:destroy)

      expect { dce.delete_entries }.to nap(0)
    end

    it "pops when no cache entries remain" do
      cache_entries_dataset = instance_double(Sequel::Dataset)
      expect(repository).to receive(:cache_entries_dataset).and_return(cache_entries_dataset)
      expect(cache_entries_dataset).to receive(:first).and_return(nil)

      expect { dce.delete_entries }.to exit({"msg" => "all cache entries deleted"})
    end
  end
end
