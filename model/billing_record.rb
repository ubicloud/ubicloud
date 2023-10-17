# frozen_string_literal: true

require_relative "../model"

class BillingRecord < Sequel::Model
  many_to_one :project

  dataset_module do
    def active
      where { {Sequel.function(:upper, :span) => nil} }
    end
  end

  include ResourceMethods

  def duration(begin_time, end_time)
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
