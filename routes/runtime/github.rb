# frozen_string_literal: true

class CloverRuntime
  hash_branch("github") do |r|
    if (runner = GithubRunner[vm_id: @vm.id]).nil? || (repository = runner.repository).nil?
      fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization header")
    end

    repository.setup_blob_storage unless repository.access_key
  end
end
