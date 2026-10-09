# frozen_string_literal: true

class Prog::Github::MaintainRepositoryBucketPool < Prog::Base
  frame_accessor :last_bucket_created

  STRAND_ID = "ffffffff-ff00-833a-87c1-0b017b64dda0" # stzzzzzzzz021gz0gp0bvcket0
  MIN_BUCKETS = 20
  MIN_WAIT_BETWEEN_BUCKETS_SECONDS = 10

  def self.schedule_strand
    Strand.where(id: STRAND_ID, label: "wait").update(schedule: Strand::SCHEDULE_NO_LATER_THAN_NOW)
  end

  label def wait
    nap_time = last_bucket_created + MIN_WAIT_BETWEEN_BUCKETS_SECONDS - now
    nap(nap_time) if nap_time > 0

    if GithubRepositoryBucketPool.count < MIN_BUCKETS
      register_deadline("wait", 5 * 60)
      hop_create_bucket
    end

    nap(60 * 60)
  end

  label def create_bucket
    ubid = UBID.generate("et")
    bucket_name = ubid.to_s
    token_id, token = GithubRepository.create_bucket(bucket_name, rescue_bucket_already_owned: false)
    GithubRepositoryBucketPool.create_with_id(ubid.to_uuid, access_key: token_id, secret_key: Digest::SHA256.hexdigest(token))
    Clog.emit("Blob storage setup completed", {blob_storage_setup_completed: {bucket_name:}})
    self.last_bucket_created = now
    hop_wait
  end

  def now
    Time.now.to_i
  end
end
