# frozen_string_literal: true

require "time"
require "stripe"

class InvoiceGenerator
  def initialize(begin_time, end_time, save_result: false, project_ids: [])
    @begin_time = begin_time
    @end_time = end_time
    @save_result = save_result
    @project_ids = project_ids
  end

  def run
    invoices = []

    DB.transaction do
      active_billing_records.group_by { |br| br[:project] }.each do |project, project_records|
        project_content = {}

        project_content[:project_id] = project.id
        project_content[:project_name] = project.name
        project_content[:billing_info] = Serializers::BillingInfo.serialize(project.billing_info)
        project_content[:issuer_info] = {
          name: "Ubicloud Inc.",
          address: "310 Santa Ana Avenue",
          country: "US",
          city: "San Francisco",
          state: "CA",
          postal_code: "94127"
        }

        project_content[:resources] = []
        project_content[:subtotal] = 0
        project_records.group_by { |pr| [pr[:resource_id], pr[:resource_name]] }.each do |(resource_id, resource_name), line_items|
          resource_content = {}
          resource_content[:resource_id] = resource_id
          resource_content[:resource_name] = resource_name

          resource_content[:line_items] = []
          resource_content[:cost] = 0
          line_items.each do |li|
            line_item_content = {}
            line_item_content[:location] = li[:location]
            line_item_content[:resource_type] = li[:resource_type]
            line_item_content[:resource_family] = li[:resource_family]
            line_item_content[:description] = BillingRate.line_item_description(li[:resource_type], li[:resource_family], li[:amount])
            line_item_content[:amount] = li[:amount].to_f
            line_item_content[:duration] = li[:duration]
            line_item_content[:cost] = li[:cost].to_f

            resource_content[:line_items].push(line_item_content)
            resource_content[:cost] += line_item_content[:cost]
          end

          project_content[:resources].push(resource_content)
          project_content[:subtotal] += resource_content[:cost]
        end

        # We first apply discounts then credits, this is more beneficial for users as it
        # would be possible to cover total cost with fewer credits.
        project_content[:cost] = project_content[:subtotal]
        project_content[:discount] = 0
        if project.discount > 0
          project_content[:discount] = (project_content[:cost] * (project.discount / 100.0)).round(3)
          project_content[:cost] -= project_content[:discount]
        end

        project_content[:credit] = 0
        if project.credit > 0
          project_content[:credit] = [project_content[:cost], project.credit.to_f].min.round(3)
          project_content[:cost] -= project_content[:credit]
        end

        # Each project have $1 github runner credit every month
        # 1$ github credit won't be shown on the portal billing page for now.
        github_usage = project_content[:resources].flat_map { _1[:line_items] }.select { _1[:resource_type] == "GitHubRunnerMinutes" }.sum { _1[:cost] }
        github_credit = [1.0, github_usage, project_content[:cost]].min
        if github_credit > 0
          project_content[:github_credit] = github_credit
          project_content[:credit] += project_content[:github_credit]
          project_content[:cost] -= project_content[:github_credit]
        end
        project_content[:cost] = project_content[:cost].round(3)

        if @save_result
          invoice_month = @begin_time.strftime("%y%m")
          invoice_customer = project.id[-10..]
          invoice_order = format("%04d", project.invoices.count + 1)
          invoice_number = "#{invoice_month}-#{invoice_customer}-#{invoice_order}"

          invoice = Invoice.create_with_id(project_id: project.id, invoice_number: invoice_number, content: project_content, begin_time: @begin_time, end_time: @end_time)

          # Don't substract the 1$ credit from customer's overall credit as it will be applied each month to each customer
          project_content[:credit] -= project_content.fetch(:github_credit, 0)
          if project_content[:credit] > 0
            # We don't use project.credit here, because credit might get updated between
            # the time we read and write. Referencing credit column here prevents such
            # race conditions. If credit got increased, then there is no problem. If it
            # got decreased, CHECK constraint in the DB will prevent credit balance to go
            # negative.
            # We also need to disable Sequel validations, because Sequel simplychecks if
            # the new value is BigDecimal, but "Sequel[:credit] - project_content[:credit]" expression
            # is Sequel::SQL::NumericExpression, not BigDecimal. Eventhough it resolves to
            # BigDecimal, it fails the check.
            # Finally, we use save_changes instead of update because it is not possible to
            # pass validate: false to update.
            project.credit = Sequel[:credit] - project_content[:credit].round(3)
            project.save_changes(validate: false)
          end
        else
          invoice = Invoice.new(project_id: project.id, content: JSON.parse(project_content.to_json), begin_time: @begin_time, end_time: @end_time, created_at: Time.now, status: "current")
        end

        invoices.push(invoice)
      end
    end

    invoices
  end

  def active_billing_records
    active_billing_records = BillingRecord.eager(project: [:billing_info, :invoices])
      .where { |br| Sequel.pg_range(br.span).overlaps(Sequel.pg_range(@begin_time...@end_time)) }
    active_billing_records = active_billing_records.where(project_id: Sequel.any_uuid(@project_ids)) unless @project_ids.empty?
    active_billing_records.all.map do |br|
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
        cost: (br.amount * duration * br.billing_rate["unit_price"]).round(3),
        duration: duration
      }
    end
  end
end
