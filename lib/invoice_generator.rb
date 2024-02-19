# frozen_string_literal: true

require "time"
require "stripe"

class InvoiceGenerator
  def initialize(begin_time, end_time, save_result: false, project_id: nil)
    @begin_time = begin_time
    @end_time = end_time
    @save_result = save_result
    @project_id = project_id
  end

  def run
    invoices = []

    DB.transaction do
      active_billing_records.group_by { |br| br[:project] }.each do |project, project_records|
        project_content = {}

        project_content[:project_id] = project.id
        project_content[:project_name] = project.name
        project_content[:billing_info] = Serializers::Web::BillingInfo.serialize(project.billing_info)
        project_content[:issuer_info] = {
          address: "310 Santa Ana Avenue",
          country: "US",
          city: "San Francisco",
          state: "CA",
          postal_code: "94127"
        }

        # To keep invoice as it is, keep the resources on the project level. It can be moved to
        # resource type level once the invoice structure is updated.
        project_content[:resources] = []
        project_content[:subtotal] = 0
        existing_resource_types = []
        project_records.group_by { |pr| pr[:resource_type] }.each do |resource_type, resource_type_records|
          existing_resource_types.push(resource_type)
          resource_type_content = {}
          resource_type_content[:subtotal] = 0
          resource_type_content[:discount] = 0
          resource_type_content[:credit] = 0
          resource_type_content[:concessions] = project.concessions.find_all { |concession| concession.resource_type == resource_type }

          resource_type_records.group_by { |rtr| [rtr[:resource_id], rtr[:resource_name]] }.each do |(resource_id, resource_name), line_items|
            resource_content = {}
            resource_content[:resource_id] = resource_id
            resource_content[:resource_name] = resource_name

            resource_content[:line_items] = []
            resource_content[:cost] = 0
            line_items.each do |li|
              line_item_content = {}
              line_item_content[:location] = li[:location]
              line_item_content[:resource_type] = resource_type
              line_item_content[:resource_family] = li[:resource_family]
              line_item_content[:description] = BillingRate.line_item_description(resource_type, li[:resource_family], li[:amount])
              line_item_content[:amount] = li[:amount].to_f
              line_item_content[:duration] = li[:duration]
              line_item_content[:cost] = li[:cost].to_f

              resource_content[:line_items].push(line_item_content)
              resource_content[:cost] += line_item_content[:cost]
            end

            project_content[:resources].push(resource_content)
            resource_type_content[:subtotal] += resource_content[:cost]
          end

          resource_type_content[:cost] = resource_type_content[:subtotal]
          project_content[:subtotal] += resource_type_content[:subtotal]
          project_content[resource_type] = resource_type_content
        end

        project_content[:cost] = project_content[:subtotal]
        project_content[:discount] = 0
        project_content[:credit] = 0
        # Apply resource level concessions first, then project level ones
        existing_resource_types.each do |resource_type|
          apply_concessions(project_content, project_content[resource_type][:concessions], resource_type)

          # Removing the resource type level keys to keep invoice as it is
          # TODO: Remove it once invoice structure will be updated
          project_content.delete(resource_type)
        end

        apply_concessions(project_content, project.concessions.find_all { |concession| concession.resource_type.nil? }, nil)

        if @save_result
          invoice_month = @begin_time.strftime("%y%m")
          invoice_customer = project.id[-10..]
          invoice_order = format("%04d", project.invoices.count + 1)
          invoice_number = "#{invoice_month}-#{invoice_customer}-#{invoice_order}"

          invoice = Invoice.create_with_id(project_id: project.id, invoice_number: invoice_number, content: project_content, begin_time: @begin_time, end_time: @end_time)
        else
          invoice = Invoice.new(project_id: project.id, content: JSON.parse(project_content.to_json), begin_time: @begin_time, end_time: @end_time, created_at: Time.now, status: "current")
        end

        invoices.push(invoice)
      end
    end

    invoices
  end

  def apply_concessions(project_content, concessions, resource_type)
    # First apply discounts and then credits
    concessions.each do |concession|
      if resource_type
        discount_amount = project_content[resource_type][:cost] * (concession.discount / 100.0)
        project_content[resource_type][:discount] += discount_amount
        project_content[resource_type][:cost] -= discount_amount
      else
        discount_amount = project_content[:cost] * (concession.discount / 100.0)
      end

      project_content[:discount] += discount_amount
      project_content[:cost] -= discount_amount
    end

    # TODO: Remove this very hacky check once the discount information will be removed from project model
    if resource_type.nil?
      discount_amount = project_content[:cost] * (Project[project_content[:project_id]].discount / 100.0)
      project_content[:discount] += discount_amount
      project_content[:cost] -= discount_amount
    end

    concessions.each do |concession|
      if resource_type
        credit_amount = [project_content[resource_type][:cost], concession.credit.to_f].min
        project_content[resource_type][:cost] -= credit_amount
        project_content[resource_type][:credit] += credit_amount
      else
        credit_amount = [project_content[:cost], concession.credit.to_f].min
      end

      project_content[:cost] -= credit_amount
      project_content[:credit] += credit_amount
      concession.credit -= credit_amount
      concession.update
    end

    # TODO: Remove this very hacky check once the credit information will be removed from project model
    if resource_type.nil?
      project = Project[project_content[:project_id]]
      project_credit_amount = project.credit.to_f
      apply_credit_amount = [project_content[:cost], project_credit_amount].min
      project_content[:credit] += apply_credit_amount
      project_content[:cost] -= apply_credit_amount
      project.credit = project_credit_amount - apply_credit_amount
      project.save_changes
    end
  end

  def active_billing_records
    active_billing_records = BillingRecord.eager(project: [:billing_info, :invoices, :concessions])
      .where { |br| Sequel.pg_range(br.span).overlaps(Sequel.pg_range(@begin_time...@end_time)) }
    active_billing_records = active_billing_records.where(project_id: @project_id) if @project_id
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
        cost: (br.amount * duration * br.billing_rate["unit_price"]),
        duration: duration
      }
    end
  end
end
