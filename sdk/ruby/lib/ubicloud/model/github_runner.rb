# frozen_string_literal: true

module Ubicloud
  class GithubRunner < BaseModel
    set_direct_columns :id, :repository_name, :label, :vcpus, :arch, :status, :created_at

    def initialize(adapter, values)
      @adapter = adapter
      @values = {}
      merge_into_values(values)
    end
  end
end
