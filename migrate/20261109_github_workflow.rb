# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_active_workflow_run) do
      uuid :id, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 540) # UBID.to_base32_n("gw") => 540
      foreign_key :installation_id, :github_installation, type: :uuid, null: false
      foreign_key :repository_id, :github_repository, type: :uuid, null: false
      Date :create_date, null: false
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      Time :run_started_at
      Time :completed_at
      Bignum :run_id, null: false
      int2 :run_attempt, null: false
      String :repository_name, null: false
      String :head_branch
      String :head_repository_full_name, collate: '"C"'
      String :event, collate: '"C"', null: false
      String :status, collate: '"C"', null: false
      String :conclusion, collate: '"C"'
      String :display_title, null: false
      String :commit_hash
      String :commit_message
      String :actor_login, collate: '"C"', null: false
      String :cache_scope, collate: '"C"', null: false

      index [:installation_id, :repository_name, :run_id, :run_attempt]
      index [:repository_id, :run_id, :run_attempt], unique: true
      index [:repository_id, Sequel.desc(:created_at)], name: :github_active_workflow_run_repository_id_created_at_idx
      index [:installation_id, Sequel.desc(:created_at)], name: :github_active_workflow_run_installation_id_created_at_idx
    end

    create_table(:github_completed_workflow_run, partition_by: :create_date, partition_type: :range) do
      uuid :repository_id # deliberately not foreign key
      Bignum :run_id
      int2 :run_attempt
      Date :create_date
      primary_key [:repository_id, :create_date, :run_id, :run_attempt]

      uuid :installation_id, null: false # deliberately not foreign key
      Time :created_at, null: false
      Time :run_started_at
      Time :completed_at
      String :head_branch
      String :head_repository_full_name, collate: '"C"'
      String :event, collate: '"C"', null: false
      String :status, collate: '"C"', null: false
      String :conclusion, collate: '"C"'
      String :display_title, null: false
      String :commit_hash
      String :commit_message
      String :actor_login, collate: '"C"', null: false
      Integer :duration

      index [:repository_id, Sequel.desc(:completed_at)], name: :github_completed_workflow_run_repository_id_completed_at_idx
      index [:installation_id, Sequel.desc(:completed_at)], name: :github_completed_workflow_run_installation_id_completed_at_idx
    end

    create_table(:github_completed_workflow_job, partition_by: :workflow_run_create_date, partition_type: :range) do
      uuid :repository_id # deliberately not foreign key
      Bignum :job_id
      Date :workflow_run_create_date
      primary_key [:repository_id, :workflow_run_create_date, :job_id]

      uuid :installation_id, null: false # deliberately not foreign key
      uuid :runner_id, null: false # deliberately not foreign key
      uuid :runner_vm_id, null: false # deliberately not foreign key
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      Time :completed_at, null: false
      Bignum :run_id, null: false
      int2 :run_attempt, null: false
      String :head_branch
      String :workflow_name
      String :job_name, null: false
      Time :job_created_at, null: false
      Time :job_started_at, null: false
      Time :job_completed_at
      Time :ready_at, null: false
      String :status, collate: '"C"', null: false
      String :conclusion, collate: '"C"'
      String :label, collate: '"C"', null: false
      String :actual_label, collate: '"C"', null: false
      String :billed_vm_size, collate: '"C"', null: false
      String :vm_family, collate: '"C"', null: false
      Integer :duration, null: false

      index [:repository_id, :run_id, :run_attempt, :job_id]
      index [:repository_id, Sequel.desc(:completed_at)], name: :github_completed_workflow_job_repository_id_completed_at_idx
      index [:installation_id, Sequel.desc(:completed_at)], name: :github_completed_workflow_job_installation_id_completed_at_idx
    end

    alter_table(:github_runner) do
      add_column :job_id, :bigint
      add_column :run_id, :bigint
      add_column :run_attempt, :int2
      add_column :head_branch, String
      add_column :workflow_name, String
      add_column :job_name, String
      add_column :completed_at, Time
      add_column :job_created_at, Time
      add_column :job_started_at, Time
      add_column :job_completed_at, Time
      add_column :status, String, collate: '"C"'
      add_column :conclusion, String, collate: '"C"'
      add_column :cache_scope, String, collate: '"C"'
    end
  end
end
