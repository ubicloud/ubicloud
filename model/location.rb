# frozen_string_literal: true

require_relative "../model"

class Location < Sequel::Model
  include ResourceMethods

  def billing_name
    if customer_aws_region_id
      name.split("-")[1..3].join("-")
    else
      name
    end
  end
end

# Table: location
# Columns:
#  id                     | uuid    | PRIMARY KEY
#  display_name           | text    | NOT NULL
#  name                   | text    | NOT NULL
#  ui_name                | text    | NOT NULL
#  visible                | boolean | NOT NULL
#  provider               | text    | NOT NULL
#  customer_aws_region_id | uuid    |
# Indexes:
#  location_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  location_customer_aws_region_id_fkey | (customer_aws_region_id) REFERENCES customer_aws_region(id)
#  location_provider_fkey               | (provider) REFERENCES provider(name)
