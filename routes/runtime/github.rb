# frozen_string_literal: true

class Clover
  hash_branch(:runtime_prefix, "github") do |r|
    if (runner = GithubRunner[vm_id: @vm.id]).nil? || (repository = runner.repository).nil?
      fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization header")
    end

    begin
      repository.setup_blob_storage unless repository.access_key
    rescue Excon::Error::HTTPStatus => ex
      Clog.emit("Unable to setup blob storage") { {failed_blob_storage_setup: {ubid: runner.ubid, repository_ubid: repository.ubid, response: ex.response.body}} }
      fail CloverError.new(400, "InvalidRequest", "unable to setup blob storage")
    end

    # getCacheEntry
    r.get "cache" do
      keys, version = r.params["keys"]&.split(","), r.params["version"]
      fail CloverError.new(400, "InvalidRequest", "Wrong parameters") if keys.nil? || keys.empty? || version.nil?

      dataset = repository.cache_entries_dataset.exclude(committed_at: nil).where(version: version)

      unless repository.installation.project.get_ff_access_all_cache_scopes
        # Clients can send multiple keys, and we look for caches in multiple scopes.
        # We prioritize scope over key, returning the cache for the first matching
        # key in the head branch scope, followed by the first matching key in
        # default branch scope.
        scopes = [runner.workflow_job&.dig("head_branch") || get_scope_from_github(runner, r.params["runId"]), repository.default_branch]
        scopes.compact!
        scopes.uniq!

        dataset = dataset.where(scope: scopes)
          .order(Sequel.case(scopes.map.with_index { |scope, idx| [{scope:}, idx] }.to_h, scopes.length))
      end

      entry = dataset
        .where(key: keys)
        .order_append(Sequel.case(keys.map.with_index { |key, idx| [{key:}, idx] }.to_h, keys.length))
        .first

      # GitHub cache supports prefix match if the key doesn't match exactly.
      # From their docs:
      #   When a key doesn't match directly, the action searches for keys
      #   prefixed with the restore key. If there are multiple partial matches
      #   for a restore key, the action returns the most recently created cache.
      #
      # We still prioritize scope over key in this case, and if there are
      # multiple prefix matches for a key, this chooses the most recent.
      entry ||= dataset
        .grep(:key, keys.map { |key| "#{DB.dataset.escape_like(key)}%" })
        .order_append(Sequel.case(keys.map.with_index { |key, idx| [Sequel.like(:key, "#{DB.dataset.escape_like(key)}%"), idx] }.to_h, keys.length), Sequel.desc(:created_at))
        .first

      entry_updated = entry && entry.this.update(last_accessed_at: Sequel::CURRENT_TIMESTAMP, last_accessed_by: runner.id) == 1

      # If was not found or entry no longer exists, return 204 to indicate so to GitHub.
      next 204 unless entry_updated

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
          .where(key: key, scope: scopes)
          .order(:version).all

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
        size = r.params["cacheSize"]&.to_i
        fail CloverError.new(400, "InvalidRequest", "Wrong parameters") if key.nil? || version.nil?

        unless (scope = runner.workflow_job&.dig("head_branch") || get_scope_from_github(runner, r.params["runId"]))
          Clog.emit("The runner does not have a workflow job") { {no_workflow_job: {ubid: runner.ubid, repository_ubid: repository.ubid}} }
          fail CloverError.new(400, "InvalidRequest", "No workflow job data available")
        end

        if size && size > GithubRepository::CACHE_SIZE_LIMIT
          fail CloverError.new(400, "InvalidRequest", "The cache size is over the 10GB limit")
        end

        entry, upload_id = nil, nil
        DB.transaction do
          begin
            entry = GithubCacheEntry.create_with_id(repository_id: runner.repository.id, key: key, version: version, size: size, scope: scope, created_by: runner.id)
          rescue Sequel::ValidationFailed, Sequel::UniqueConstraintViolation
            fail CloverError.new(409, "AlreadyExists", "A cache entry for #{scope} scope already exists with #{key} key and #{version} version.")
          end

          # Token creation on Cloudflare R2 takes time to propagate. Since that point is the
          # first time we use the credentials, we are waiting it to be propagated. Note that,
          # credential propagation will happen only while the bucket and token are being created
          # initially. So, the retry block expected to run only while saving the first cache
          # entry for a repository.
          retries = 0
          begin
            upload_id = repository.blob_storage_client.create_multipart_upload(bucket: repository.bucket_name, key: entry.blob_key).upload_id
          rescue Aws::S3::Errors::Unauthorized, Aws::S3::Errors::InternalError => ex
            retries += 1
            if retries < 3
              # :nocov:
              sleep(1) unless Config.test?
              # :nocov:
              retry
            else
              Clog.emit("Could not authorize multipart upload") { {could_not_authorize_multipart_upload: {ubid: runner.ubid, repository_ubid: repository.ubid, exception: Util.exception_to_hash(ex)}} }
              fail CloverError.new(400, "InvalidRequest", "Could not authorize multipart upload")
            end
          end

          entry.update(upload_id:)
        end

        # If size is not provided, it means that the client doesn't
        # let us know the size of the cache. In this case, we use the
        # GithubRepository::CACHE_SIZE_LIMIT as the size.
        size ||= GithubRepository::CACHE_SIZE_LIMIT

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
        fail CloverError.new(204, "NotFound", "No cache entry") if entry.nil? || (entry.size && entry.size != size)

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

        updates = {committed_at: Time.now}
        # If the size can not be set with reserveCache, we set it here.
        updates[:size] = size if entry.size.nil?

        entry.update(updates)

        {}
      end
    end
  end
end
