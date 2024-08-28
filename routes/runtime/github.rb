# frozen_string_literal: true

class CloverRuntime
  hash_branch("github") do |r|
    if (runner = GithubRunner[vm_id: @vm.id]).nil? || (repository = runner.repository).nil?
      fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization header")
    end

    repository.setup_blob_storage unless repository.access_key

    # getCacheEntry
    r.get "cache" do
      keys, version = r.params["keys"]&.split(","), r.params["version"]
      fail CloverError.new(400, "InvalidRequest", "Wrong parameters") if keys.nil? || keys.empty? || version.nil?

      # Clients can send multiple keys; we return the first matching cache in
      # incoming key order. The function `.min_by { keys.index(_1.key) }` helps
      # us achieve this by ordering entries based on the index of key in the
      # given order. If the same cache exists for both the head_branch and the
      # default branch, we prioritize and return the cache for the head_branch.
      # The part `(scopes.index(_1.scope) * keys.size)` assists in sorting the
      # caches by scope, pushing entries for later scopes to the end of the
      # list.
      scopes = [runner.workflow_job&.dig("head_branch"), repository.default_branch].compact
      entry = repository.cache_entries_dataset
        .exclude(committed_at: nil)
        .where(key: keys, version: version, scope: scopes).all
        .min_by { keys.index(_1.key) + (scopes.index(_1.scope) * keys.size) }

      fail CloverError.new(204, "NotFound", "No cache entry") if entry.nil?

      entry.update(last_accessed_at: Time.now, last_accessed_by: runner.id)
      signed_url = repository.url_presigner.presigned_url(:get_object, bucket: repository.bucket_name, key: entry.blob_key, expires_in: 900)

      {
        scope: entry.scope,
        cacheKey: entry.key,
        cacheVersion: entry.version,
        creationTime: entry.created_at,
        archiveLocation: signed_url
      }
    end

    r.on "caches" do
      # listCache
      r.get true do
        key = r.params["key"]
        fail CloverError.new(204, "NotFound", "No cache entry") if key.nil?

        scopes = [runner.workflow_job&.dig("head_branch"), repository.default_branch].compact
        entries = repository.cache_entries_dataset
          .exclude(committed_at: nil)
          .where(key: key, scope: scopes).all

        {
          totalCount: entries.count,
          artifactCaches: entries.map do
            {
              scope: _1.scope,
              cacheKey: _1.key,
              cacheVersion: _1.version,
              creationTime: _1.created_at
            }
          end
        }
      end

      # reserveCache
      r.post true do
        key = r.params["key"]
        version = r.params["version"]
        size = r.params["cacheSize"].to_i
        fail CloverError.new(400, "InvalidRequest", "Wrong parameters") if key.nil? || version.nil? || size == 0

        unless (scope = runner.workflow_job&.dig("head_branch"))
          # YYYY: If the webhook not delivered yet, we can try to get the branch from the API
          Clog.emit("The runner does not have a workflow job") { {no_workflow_job: {ubid: runner.ubid, repository_ubid: repository.ubid}} }
          fail CloverError.new(400, "InvalidRequest", "No workflow job data available")
        end

        if repository.cache_entries_dataset[key: key, version: version, scope: scope]
          fail CloverError.new(409, "AlreadyExists", "A cache entry for #{scope} scope already exists with #{key} key and #{version} version.")
        end

        if size > GithubRepository::CACHE_SIZE_LIMIT
          fail CloverError.new(400, "InvalidRequest", "The cache size is over the 10GB limit")
        end

        entry, upload_id = nil, nil
        DB.transaction do
          entry = GithubCacheEntry.create_with_id(repository_id: runner.repository.id, key: key, version: version, size: size, scope: scope, created_by: runner.id)
          upload_id = repository.blob_storage_client.create_multipart_upload(bucket: repository.bucket_name, key: entry.blob_key).upload_id
          entry.update(upload_id: upload_id)
        end

        max_chunk_size = 32 * 1024 * 1024 # 32MB
        presigned_urls = (1..size.fdiv(max_chunk_size).ceil).map do
          repository.url_presigner.presigned_url(:upload_part, bucket: repository.bucket_name, key: entry.blob_key, upload_id: upload_id, part_number: _1, expires_in: 900)
        end

        {
          uploadId: upload_id,
          presignedUrls: presigned_urls,
          chunkSize: max_chunk_size
        }
      end

      # commitCache
      r.post "commit" do
        etags = r.params["etags"]
        upload_id = r.params["uploadId"]
        size = r.params["size"].to_i
        fail CloverError.new(400, "InvalidRequest", "Wrong parameters") if etags.nil? || etags.empty? || upload_id.nil? || size == 0

        entry = GithubCacheEntry[repository_id: repository.id, upload_id: upload_id, committed_at: nil]
        fail CloverError.new(204, "NotFound", "No cache entry") if entry.nil? || entry.size != size

        begin
          repository.blob_storage_client.complete_multipart_upload({
            bucket: repository.bucket_name,
            key: entry.blob_key,
            upload_id: upload_id,
            multipart_upload: {parts: etags.map.with_index { {part_number: _2 + 1, etag: _1} }}
          })
        rescue Aws::S3::Errors::InvalidPart, Aws::S3::Errors::NoSuchUpload => ex
          Clog.emit("could not complete multipart upload") { {failed_multipart_upload: {ubid: runner.ubid, repository_ubid: repository.ubid, exception: Util.exception_to_hash(ex)}} }
          fail CloverError.new(400, "InvalidRequest", "Wrong parameters")
        end

        entry.update(committed_at: Time.now)

        {}
      end
    end
  end
end
