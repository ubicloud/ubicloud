# frozen_string_literal: true

class CloverRuntime
  hash_branch("github") do |r|
    if (runner = GithubRunner[vm_id: @vm.id]).nil? || (repository = runner.repository).nil?
      fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization header")
    end

    repository.setup_blob_storage unless repository.access_key

    r.on "caches" do
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

        if size > 10 * 1024 * 1024 * 1024
          fail CloverError.new(400, "InvalidRequest", "The cache size is over the 10GB limit")
        end

        entry = GithubCacheEntry.create_with_id(repository_id: runner.repository.id, key: key, version: version, size: size, scope: scope, created_by: runner.id)

        upload_id = repository.blob_storage_client.create_multipart_upload(bucket: repository.bucket_name, key: entry.blob_key).upload_id
        entry.update(upload_id: upload_id)

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
    end
  end
end
