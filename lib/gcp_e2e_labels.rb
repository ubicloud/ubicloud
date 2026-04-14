# frozen_string_literal: true

# Scopes Ubicloud-created GCP resources to a specific E2E workflow run.
#
# When ENV["E2E_RUN_ID"] is set (the E2E workflow wires ${{ github.run_id }}
# into the Run tests step), every GCP create call in the provider tags the
# created resource with label e2e_run_id=<run_id>. The cleanup step in
# .github/workflows/e2e.yml scopes its deletes by that label so one run can
# never tear down another run's resources.
#
# Resource types whose GCP API does not accept arbitrary labels (network
# firewall policies, resource-manager tag keys/values, IAM service accounts)
# encode the run id in the description field instead; gcloud cleanup filters
# match that token (e2e_run_id=<run_id>) client-side.
module GcpE2eLabels
  def self.run_id
    id = ENV["E2E_RUN_ID"]
    (id.nil? || id.empty?) ? nil : id
  end

  # Hash suitable for merging into a GCP labels field. Empty outside E2E runs,
  # so .merge() is a no-op on developer/production create paths.
  def self.labels_hash
    (rid = run_id) ? {"e2e_run_id" => rid} : {}
  end

  # Suffix to append to a resource description. Empty outside E2E runs.
  # The token is wrapped in square brackets so gcloud --filter can match
  # it with substring semantics without colliding on run-id prefixes
  # (e.g. run 12345 vs run 123456789).
  def self.description_suffix
    (rid = run_id) ? " [e2e_run_id=#{rid}]" : ""
  end
end
