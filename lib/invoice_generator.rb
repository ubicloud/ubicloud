# frozen_string_literal: true

require "time"
require "stripe"

class InvoiceGenerator
  def initialize(begin_time, end_time, save_result: false, project_ids: [], eur_rate: nil)
    @begin_time = begin_time
    @end_time = end_time
    @save_result = save_result
    @project_ids = project_ids
    @eur_rate = eur_rate
    if @save_result && !@eur_rate
      raise ArgumentError, "eur_rate must be provided when save_result is true"
    end
  end

  def run
    invoices = []

    DB.transaction do
      active_billing_records.group_by { |br| br[:project] }.each do |project, project_records|
        project_content = {}
        project_content[:project_id] = project.id
        project_content[:project_name] = project.name
        bi = project.billing_info
        country = bi&.country
        is_eu = country&.in_eu_vat?
        project_content[:billing_info] = bi&.stripe_data&.merge({
          "id" => bi.id,
          "ubid" => bi.ubid,
          "in_eu_vat" => !!is_eu
        })
        # Invoices are issued by Ubicloud Inc. for non-EU customers without VAT applied.
        # Invoices are issued by Ubicloud B.V. for EU customers.
        #   - If the customer has provided a VAT number from the Netherlands, we charge 21% VAT.
        #   - If the customer has provided a VAT number from another European country, we include a reverse charge notice along with 0% VAT.
        #   - If the customer hasn't provided a VAT number, we charge 21% VAT until non-Dutch EU sales exceed annual threshold, than we charge local VAT.
        project_content[:issuer_info] = if is_eu
          {
            name: "Ubicloud B.V.",
            address: "Turfschip 267",
            country: "NL",
            city: "Amstelveen",
            postal_code: "1186 XK",
            tax_id: "NL864651442B01",
            trade_id: "88492729",
            in_eu_vat: true
          }
        else
          {
            name: "Ubicloud Inc.",
            address: "310 Santa Ana Avenue",
            country: "US",
            city: "San Francisco",
            state: "CA",
            postal_code: "94127"
          }
        end
        vat_info = if is_eu
          if (tax_id = project_content[:billing_info]["tax_id"]) && !tax_id.empty? && country.alpha2 != "NL"
            {rate: 0, reversed: true}
          else
            {rate: Config.annual_non_dutch_eu_sales_exceed_threshold ? country.vat_rates["standard"] : 21, reversed: false, eur_rate: @eur_rate}
          end
        end
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
            line_item_content[:begin_time] = li[:begin_time].utc
            line_item_content[:unit_price] = li[:unit_price].to_f

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
        github_usage = project_content[:resources].flat_map { it[:line_items] }.select { it[:resource_type] == "GitHubRunnerMinutes" }.sum { it[:cost] }
        github_credit = [1.0, github_usage, project_content[:cost]].min
        if github_credit > 0
          project_content[:github_credit] = github_credit
          project_content[:credit] += project_content[:github_credit]
          project_content[:cost] -= project_content[:github_credit]
        end

        # Each project have some free AI inference tokens every month
        # Free AI tokens WILL be shown on the portal billing page as a separate credit.
        free_inference_tokens_remaining = FreeQuota.free_quotas["inference-tokens"]["value"]
        free_inference_tokens_credit = 0.0
        project_content[:resources]
          .flat_map { it[:line_items] }
          .select { it[:resource_type] == "InferenceTokens" }
          .sort_by { |li| [li[:begin_time].to_date, -li[:unit_price]] }
          .each do |li|
            used_amount = [li[:amount], free_inference_tokens_remaining].min
            free_inference_tokens_remaining -= used_amount
            free_inference_tokens_credit += used_amount * li[:unit_price]
          end
        free_inference_tokens_credit = [free_inference_tokens_credit, project_content[:cost]].min
        if free_inference_tokens_credit > 0
          project_content[:free_inference_tokens_credit] = free_inference_tokens_credit
          project_content[:cost] -= project_content[:free_inference_tokens_credit]
        end

        if project_content[:cost] < Config.minimum_invoice_charge_threshold
          vat_info = nil
        end
        project_content[:vat_info] = vat_info

        if vat_info && !vat_info[:reversed]
          project_content[:vat_info][:amount] = (project_content[:cost] * vat_info[:rate].fdiv(100)).round(3)
          project_content[:cost] += project_content[:vat_info][:amount]
        end
        project_content[:cost] = project_content[:cost].round(3)

        if @save_result
          invoice_month = @begin_time.strftime("%y%m")
          invoice_customer = project.id[-10..]
          invoice_order = format("%04d", project.invoices.count + 1)
          invoice_number = "#{invoice_month}-#{invoice_customer}-#{invoice_order}"

          invoice = Invoice.create(project_id: project.id, invoice_number: invoice_number, content: project_content, begin_time: @begin_time, end_time: @end_time)

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
    active_billing_records = active_billing_records.where(project_id: @project_ids) unless @project_ids.empty?
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
        duration: duration,
        begin_time: br.span.begin,
        unit_price: br.billing_rate["unit_price"]
      }
    end
  end
end
