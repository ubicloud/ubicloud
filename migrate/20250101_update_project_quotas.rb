# frozen_string_literal: true

Sequel.migration do
  up do
    run "UPDATE project_quota SET value = value * 2 WHERE quota_id IN ('c088f732-0a30-454b-aa6b-542ce1d67bfb', '14fa6820-bf63-41d2-b35e-4a4dcefd1b15', '91d616ea-a15b-4d54-90b7-aaa1e1bd2f19')"
  end

  down do
    run "UPDATE project_quota SET value = value / 2 WHERE quota_id IN ('c088f732-0a30-454b-aa6b-542ce1d67bfb', '14fa6820-bf63-41d2-b35e-4a4dcefd1b15', '91d616ea-a15b-4d54-90b7-aaa1e1bd2f19')"
  end
end
