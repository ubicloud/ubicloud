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
        project_content[:subtotal] = 0
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
          project_content[:subtotal] += resource_content[:cost]
        end

        # We first apply discounts then credits, this is more beneficial for users as it
        # would be possible to cover total cost with fewer credits.
        project_content[:cost] = project_content[:subtotal]
        if project.discount > 0
          project_content[:cost] *= (100.0 - project.discount) / 100.0
        end

        credit_used = 0
        if project.credit > 0
          credit_used = [project_content[:cost], project.credit].min
          project_content[:cost] -= credit_used
        end

        invoices.push(project_content)
        if @save_result
          invoice_month = @begin_time.strftime("%y%m")
          invoice_customer = project.id[-10..]
          invoice_order = format("%04d", project.invoices.count + 1)
          invoice_number = "#{invoice_month}-#{invoice_customer}-#{invoice_order}"

          Invoice.create_with_id(project_id: project.id, invoice_number: invoice_number, content: project_content)

          if credit_used > 0
            # We don't use project.credit here, because credit might get updated between
            # the time we read and write. Referencing credit column here prevents such
            # race conditions. If credit got increased, then there is no problem. If it
            # got decreased, CHECK constraint in the DB will prevent credit balance to go
            # negative.
            # We also need to disable Sequel validations, because Sequel simplychecks if
            # the new value is BigDecimal, but "Sequel[:credit] - credit_used" expression
            # is Sequel::SQL::NumericExpression, not BigDecimal. Eventhough it resolves to
            # BigDecimal, it fails the check.
            # Finally, we use save_changes instead of update because it is not possible to
            # pass validate: false to update.
            project.credit = Sequel[:credit] - credit_used
            project.save_changes(validate: false)
          end
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
