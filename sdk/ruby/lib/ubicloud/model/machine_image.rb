# frozen_string_literal: true

module Ubicloud
  class MachineImage < Model
    set_prefix "m1"

    set_fragment "machine-image"

    set_columns :id, :name, :location, :arch, :latest_version, :created_at, :versions

    # Return a list of versions for this machine image.
    def list_versions
      adapter.get(_path("/version"))[:items]
    end

    # Create a new version of this machine image by capturing a stopped VM.
    def create_version(version, vm:, destroy_source: nil)
      check_no_slash(version, "invalid version format")
      params = {vm:}
      params[:destroy_source] = "true" if destroy_source
      adapter.post(_path("/version/#{version}"), **params)
    end

    # Destroy a specific version of this machine image.
    def destroy_version(version)
      check_no_slash(version, "invalid version format")
      adapter.delete(_path("/version/#{version}"))
    end
  end
end
