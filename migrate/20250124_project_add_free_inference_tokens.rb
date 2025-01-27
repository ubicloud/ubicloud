# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:project) do
      add_column :free_inference_tokens, :integer, null: false, default: 0
      add_column :free_inference_tokens_updated_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
