# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:private_link_service_aws_resource) do
      foreign_key :id, :private_link_service, type: :uuid, primary_key: true, on_delete: :cascade
      column :nlb_arn, :text, collate: '"C"'
      column :service_id, :text, collate: '"C"'
      column :service_name, :text, collate: '"C"'
      # Additional regions consumers may connect from; the service's own region
      # is never stored here.
      column :supported_regions, "text[]", collate: '"C"', null: false, default: Sequel.lit("'{}'::text[]")
      column :registered_target_ips, "inet[]", null: false, default: Sequel.lit("'{}'::inet[]")
      column :private_dns_verification_state, :text, collate: '"C"'
      column :private_dns_verification_name, :text, collate: '"C"'
      column :private_dns_verification_value, :text, collate: '"C"'
      column :private_dns_verification_attempted_at, :timestamptz
      # The TXT record this service published, fully qualified, so a later run
      # removes exactly that one.
      column :private_dns_txt_record_name, :text, collate: '"C"'
    end

    create_table(:private_link_service_port_aws_resource) do
      foreign_key :id, :private_link_service_port, type: :uuid, primary_key: true, on_delete: :cascade
      column :target_group_arn, :text, collate: '"C"'
      column :listener_arn, :text, collate: '"C"'
    end

    create_table(:private_link_service_aws_allowed_endpoint) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :private_link_service_aws_resource_id, :private_link_service_aws_resource, type: :uuid, null: false, on_delete: :cascade
      column :vpc_endpoint_id, :text, collate: '"C"', null: false
      column :description, :text, collate: '"C"', null: false, default: ""

      unique [:private_link_service_aws_resource_id, :vpc_endpoint_id]
    end
  end
end
