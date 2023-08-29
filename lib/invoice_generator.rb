# frozen_string_literal: true

require "time"

class InvoiceGenerator
  def initialize(begin_time, end_time, save_result = false)
    @begin_time = begin_time
    @end_time = end_time
    @save_result = save_result
  end

  def run
    invoices = []

    DB.transaction do
      active_billing_records.group_by { |br| br[:project] }.each do |project, project_records|
        project_content = {}

        project_content[:project_id] = project.id
        project_content[:project_name] = project.name

        project_content[:resources] = []
        project_content[:cost] = 0
        project_records.group_by { |pr| pr[:resource_id] }.each do |resource_id, line_items|
          resource_content = {}
          resource_content[:resource_id] = resource_id
          resource_content[:resource_name] = line_items.first[:resource_name]

          resource_content[:line_items] = []
          resource_content[:cost] = 0
          line_items.each do |li|
            line_item_content = {}
            line_item_content[:location] = li[:location]
            line_item_content[:resource_type] = li[:resource_type]
            line_item_content[:resource_family] = li[:resource_family]
            line_item_content[:amount] = li[:amount]
            line_item_content[:cost] = li[:cost]

            resource_content[:line_items].push(line_item_content)
            resource_content[:cost] += line_item_content[:cost]
          end

          project_content[:resources].push(resource_content)
          project_content[:cost] += resource_content[:cost]
        end

        if @save_result
          invoice_month = @begin_time.strftime("%y%m")
          invoice_customer = project.id[-10..]
          invoice_order = format("%04d", project.invoices.count + 1)
          invoice_number = "#{invoice_month}-#{invoice_customer}-#{invoice_order}"

          Invoice.create_with_id(project_id: project.id, invoice_number: invoice_number, content: project_content)
        else
          invoices.push(project_content)
        end
      end
    end

    invoices
  end

  def active_billing_records
    active_billing_records = BillingRecord.eager(project: :invoices)
      .where { |br| Sequel.pg_range(br.span).overlaps(Sequel.pg_range(@begin_time...@end_time)) }
      .all

    active_billing_records.map do |br|
      # We cap the billable duration at 672 hours. In this way, we can
      # charge the users same each month no matter the number of days
      # in that month.
      duration = [672 * 60, br.duration(@begin_time, @end_time).ceil].min
      {
        project: br.project,
        resource_id: br.resource_id,
        location: br.billing_rate["location"],
        resource_name: br.resource_name,
        resource_type: br.billing_rate["resource_type"],
        resource_family: br.billing_rate["resource_family"],
        amount: br.amount,
        cost: (br.amount * duration * br.billing_rate["unit_price"])
      }
    end
  end
end
