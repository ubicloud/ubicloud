# frozen_string_literal: true

module Ubicloud
  class MachineImage < Model
    set_prefix "m1"

    set_fragment "machine-image"

    set_columns :id, :name, :location, :arch, :latest_version, :created_at

    # Set the latest version of this machine image. Pass a version label or nil to unset.
    def set_latest_version(version)
      check_no_slash(version, "invalid version format") if version
      merge_into_values(adapter.patch(_path, latest_version: version))
    end
  end
end
