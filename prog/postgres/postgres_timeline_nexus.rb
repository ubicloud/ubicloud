# frozen_string_literal: true

require "forwardable"

class Prog::Postgres::PostgresTimelineNexus < Prog::Base
  subject_is :postgres_timeline

  extend Forwardable
  def_delegators :postgres_timeline, :blob_storage_client

  semaphore :destroy

  def self.assemble(parent_id: nil)
    DB.transaction do
      postgres_timeline = PostgresTimeline.create_with_id(parent_id: parent_id)
      Strand.create(prog: "Postgres::PostgresTimelineNexus", label: "start") { _1.id = postgres_timeline.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    blob_storage_client.create_bucket(bucket_name: postgres_timeline.ubid)
    hop_wait
  end

  label def wait
    nap 30
  end

  label def destroy
    decr_destroy
    postgres_timeline.destroy
    pop "postgres timeline is deleted"
  end
end
