# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:allocation_state, %w[unprepared accepting draining])

    create_table(:strand) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :parent_id, :strand, type: :uuid
      column :schedule, :timestamptz, null: false, default: Sequel.lit("now()")
      column :lease, :timestamptz
      column :prog, :text, collate: '"C"', null: false
      column :label, :text, collate: '"C"', null: false
      column :stack, :jsonb, null: false, default: "[]"
      column :exitval, :jsonb
      column :retval, :jsonb
    end

    create_table(:semaphore) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :strand_id, :strand, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
    end

    create_table(:sshable) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :host, :text, collate: '"C"', null: false, unique: true
      column :private_key, :text, collate: '"C"'
    end

    create_table(:vm_host) do
      foreign_key :id, :sshable, type: :uuid, primary_key: true
      column :allocation_state, :allocation_state, default: "unprepared", null: false
      column :ip6, :inet, unique: true
      column :net6, :cidr, unique: true
    end

    create_table(:vm) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      column :ephemeral_net6, :cidr, unique: true

      foreign_key :vm_host_id, :vm_host, type: :uuid
    end
  end
end
