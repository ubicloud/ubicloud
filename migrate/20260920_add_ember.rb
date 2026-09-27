# frozen_string_literal: true

Sequel.migration do
  change do
    # A memory snapshot an ember VM is restored from.
    create_table(:ember_template) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 410) # UBID.to_base32_n("ct")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :location_id, :location, type: :uuid, null: false
      column :arch, :text, collate: '"C"', null: false
      constraint(:ember_template_arch_check, arch: %w[x64 arm64])
      column :cpu_signature, :text, collate: '"C"', null: false
      # What runs inside the ember, and which build of it. Placement matches on
      # both: a template built for one workload is no use to another.
      column :workload, :text, collate: '"C"', null: false
      column :version, :text, collate: '"C"', null: false
      column :root_image, :text, collate: '"C"', null: false
      # The image a fresh volume reads through to until it is written.
      column :data_image, :text, collate: '"C"', null: false
      column :ch_version, :text, collate: '"C"', null: false
      column :memory_mib, Integer, null: false, default: 384
      column :vcpus, Integer, null: false, default: 1
      column :state, :text, collate: '"C"', null: false, default: "building"
      constraint(:ember_template_state_check, state: %w[building ready retired failed])

      index [:location_id, :workload, :version, :cpu_signature, :state],
        name: "ember_template_placement_idx"
    end

    # Which hosts have built which template.
    create_table(:ember_template_host) do
      foreign_key :ember_template_id, :ember_template, type: :uuid, null: false
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      column :state, :text, collate: '"C"', null: false, default: "building"
      constraint(:ember_template_host_state_check, state: %w[building ready failed])
      primary_key [:ember_template_id, :vm_host_id]
      index [:vm_host_id], name: "ember_template_host_vm_host_id_idx"
    end

    # An ember: one micro-VM in a slot on a host, restored from a template
    # snapshot and backed by a detachable volume. Everything here is true of
    # any workload that wants to be handed out in under a second and cost
    # nothing while it is paused; what actually runs inside is the business of
    # the 1:1 row that references this one.
    create_table(:ember) do
      column :id, :uuid, primary_key: true, default: Sequel.function(:gen_random_ubid_uuid, 396) # UBID.to_base32_n("cc")
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
      column :state, :text, collate: '"C"', null: false, default: "creating"
      constraint(:ember_state_check, state: %w[creating running pausing paused resuming destroying])
      # Bumped on every state transition the control plane drives, so a host
      # can reject a mutation that was issued against a stale view.
      column :generation, Integer, null: false, default: 0
      # When the row last changed state. The nexus leaves an ember alone while
      # the synchronous path is working on it, and this is how it tells that
      # apart from a create that crashed and left the row transitional forever.
      column :state_changed_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key :vm_host_id, :vm_host, type: :uuid
      column :slot, Integer
      column :ip6, :inet
      foreign_key :ember_template_id, :ember_template, type: :uuid, null: false

      column :memory_mib, Integer, null: false, default: 384
      column :cpu_percent_limit, Integer, null: false, default: 50

      # Paused when nothing has touched it for this long, and destroyed
      # outright once it is past its lifetime unless it is protected.
      column :idle_timeout_seconds, Integer, null: false, default: 300
      column :last_activity_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :last_started_at, :timestamptz
      column :last_paused_at, :timestamptz
      column :expires_at, :timestamptz
      column :protected, FalseClass, null: false, default: false

      unique [:project_id, :name], name: "ember_project_id_name_uidx"
      # The nexus sweeps for idle embers and expired ones.
      index [:state, :last_activity_at], name: "ember_state_last_activity_idx"
      index [:expires_at], name: "ember_expires_at_idx"
      # A slot is occupied by at most one ember.
      index [:vm_host_id, :slot], unique: true,
        name: "ember_vm_host_slot_uidx", where: Sequel.~(slot: nil)
    end

    alter_table(:detachable_volume) do
      add_column :owner_id, :uuid
    end
  end
end
