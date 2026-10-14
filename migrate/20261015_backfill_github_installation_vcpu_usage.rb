# frozen_string_literal: true

Sequel.migration do
  up do
    %w[metal aws].product(%w[x64 arm64]).each do |provider, arch|
      from(:github_installation_vcpu_usage).insert_conflict.insert(
        [:installation_id, :provider, :arch, :used_vcpus],
        from(:github_installation).select(:id, provider, Sequel.cast(arch, :arch), 0),
      )
    end
  end
end
