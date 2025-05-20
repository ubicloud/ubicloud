# frozen_string_literal: true

require_relative "../model"

class BillingRecord < Sequel::Model
  many_to_one :project

  dataset_module do
    where(:active, Sequel.function(:upper, :span) => nil)
  end

  include ResourceMethods

  def duration(begin_time, end_time)
    # Billing logic differs based on the resource type: some are billed by duration, others
    # by amount. For 'VmVCpu' billing records, the core counts are stored in the amount
    # column and charges are based on duration. For example, 10 minutes of standard-4 vm
    # usage would be calculated as `10 (duration) x 2 (amount) x rate_for_standard_core`.
    # 'GitHubRunnerMinutes' records, on the other hand, store the used minutes in the
    # 'amount' column, and billing is based on that amount.
    # For records billed by amount, the duration is always set to 1.
    return 1 if billing_rate["billed_by"] == "amount"
    # begin_time and end_time refers to begin and end of the billing window. Duration of
    # BillingRecord is subjective to the billing window we are querying for. For example
    # if span of the BillingRecord is ['2023-06-15', '2023-08-20'] and billing window is
    # ['2023-06-01', '2023-07-01'], then we are only interested in duration of billing
    # record that was active in June. This is effectively calculating the intersection of
    # two time ranges.
    # One complication comes from the fact billing window might have nil end point if it
    # is still active. We check for that case with span.unbounded_end?.
    duration_begin = [span.begin, begin_time].max
    duration_end = span.unbounded_end? ? end_time : [span.end, end_time].min
    (duration_end - duration_begin) / 60
  end

  def finalize
    self.class.where(id: id).update(span: Sequel.lit("tstzrange(lower(span), now())"))
  end

  def billing_rate
    @billing_rate ||= BillingRate.from_id(billing_rate_id)
  end
end

# Table: billing_record
# Columns:
#  id              | uuid      | PRIMARY KEY
#  project_id      | uuid      | NOT NULL
#  resource_id     | uuid      | NOT NULL
#  resource_name   | text      | NOT NULL
#  span            | tstzrange | NOT NULL DEFAULT tstzrange(now(), NULL::timestamp with time zone, '[)'::text)
#  amount          | numeric   | NOT NULL
#  billing_rate_id | uuid      | NOT NULL
# Indexes:
#  billing_record_pkey              | PRIMARY KEY btree (id)
#  billing_record_project_id_index  | btree (project_id)
#  billing_record_resource_id_index | btree (resource_id)
#  billing_record_span_index        | gist (span)
