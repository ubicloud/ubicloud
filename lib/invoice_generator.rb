# frozen_string_literal: true

require "time"
require "stripe"

class InvoiceGenerator
  CURRENT_INVOICE_VERSION = 2

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
          "in_eu_vat" => !!is_eu,
        })

        project_content[:bank_transfer_info] = if bi && bi.payment_methods.empty?
          project_content[:due_date] = (Date.today + 30).to_s
          if is_eu
            {
              "Beneficiary" => "Ubicloud B.V.",
              "IBAN" => "NL30REVO6759811127",
              "BIC" => "REVONL22",
              "Intermediary BIC" => "CHASGB2L",
              "Beneficiary address" => "Turfschip, 267, 1186XK, Amstelveen, Netherlands",
              "Bank/Payment institution" => "Revolut Bank UAB",
              "Bank address" => "Barbara Strozzilaan 201, 1083 HN, Amsterdam, Netherlands",
            }
          else
            {
              "Beneficiary" => "Ubicloud Inc.",
              "Beneficiary address" => "310 Santa Ana Ave, San Francisco, CA 94127",
              "ABA/Routing number" => "121145349",
              "Account number" => "974842159957503",
              "Bank/Payment institution" => "Column NA - Brex",
              "Bank address" => "1 Letterman Drive Building A, Suite A4-700, San Francisco, CA 94129",
            }
          end
        end
        # Invoices are issued by Ubicloud Inc. for non-EU customers without VAT applied.
        # Invoices are issued by Ubicloud B.V. for EU customers.
        #   - If the customer has provided a VAT number from the Netherlands, we charge 21% VAT.
        #   - If the customer has provided a VAT number from another European country that we have validated, we include a reverse charge notice along with 0% VAT.
        #   - If the customer hasn't provided a VAT number, or the one they provided has not been validated, we charge 21% VAT until non-Dutch EU sales exceed annual threshold, than we charge local VAT.
        project_content[:issuer_info] = if is_eu
          {
            name: "Ubicloud B.V.",
            address: "Turfschip 267",
            country: "NL",
            city: "Amstelveen",
            postal_code: "1186 XK",
            tax_id: "NL864651442B01",
            trade_id: "88492729",
            in_eu_vat: true,
          }
        else
          {
            name: "Ubicloud Inc.",
            address: "310 Santa Ana Avenue",
            country: "US",
            city: "San Francisco",
            state: "CA",
            postal_code: "94127",
          }
        end
        vat_info = if is_eu
          if (tax_id = project_content[:billing_info]["tax_id"]) && !tax_id.empty? && country.alpha2 != "NL" && bi.valid_vat == true
            {rate: 0, reversed: true}
          else
            {rate: Config.annual_non_dutch_eu_sales_exceed_threshold ? country.vat_rates["standard"] : 21, reversed: false, eur_rate: @eur_rate}
          end
        end
        resource_discounts, resource_credits = [ResourceDiscount, ResourceCredit].map! do |model|
          model
            .for_project(project.id)
            .active_during(@begin_time, @end_time)
        end
        resource_discounts = resource_discounts.all
        resource_credits = resource_credits
          .where { |d| d.amount > 0 }
          .order(:active_from, :created_at)
          .all

        project_content[:resources] = []
        project_content[:subtotal] = 0
        discounts_by_name = {}

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

            if (rd = resource_discounts.find { |d| d.matches?(li) })
              percent = rd.discount_percent.to_f
              discount_amount = (line_item_content[:cost] * percent / 100.0).round(3)
              line_item_content[:discount] = {
                percent:,
                amount: discount_amount,
              }
              discount_name = rd.name.to_s.empty? ? "Resource Discount" : rd.name
              discounts_by_name[discount_name] = (discounts_by_name[discount_name] || 0.0) + discount_amount
            end

            resource_content[:line_items].push(line_item_content)
            # Subtotal reflects cost before discount
            resource_content[:cost] = (resource_content[:cost] + line_item_content[:cost]).round(3)
          end

          project_content[:resources].push(resource_content)
          project_content[:subtotal] = (project_content[:subtotal] + resource_content[:cost]).round(3)
        end

        project_content[:discount] = discounts_by_name.values.sum.round(3)
        project_content[:discounts] = discounts_by_name.map { |name, amount| {name:, amount: amount.round(3)} }
        project_cost = project_content[:cost] = (project_content[:subtotal] - project_content[:discount]).round(3)

        credits_by_name = {}
        resource_credit_consumptions = []
        line_items = project_content[:resources].flat_map do |pr|
          pr[:line_items].map do |li|
            h = li.slice(:resource_type, :resource_family, :location, :byoc)
            cost = li[:cost]
            if (discount = li[:discount])
              cost -= discount[:amount]
            end
            h[:cost] = cost.round(3)
            h
          end
        end

        # Do not allow a resource credit to remove more than the cost of the resource
        # or remove more than the total cost.
        resource_credits.each do |rc|
          base = if rc.wildcard?
            project_cost
          else
            line_items.select { rc.matches?(it) }.sum { it[:cost] }.clamp(nil, project_cost)
          end
          consumed = base.clamp(nil, rc.amount.to_f).clamp(nil, project_cost).round(3)
          next if consumed <= 0

          credits_by_name[rc.name] = (credits_by_name[rc.name] || 0.0) + consumed
          project_cost = project_content[:cost] = (project_cost - consumed).round(3)
          resource_credit_consumptions.push([rc, consumed])
        end

        # Each project have 1250 minutes (2.5$) runner credit every month
        github_usage = project_content[:resources].flat_map { it[:line_items] }.select { it[:resource_type] == "GitHubRunnerMinutes" }.sum { it[:cost] }
        github_credit = [2.5, github_usage, project_content[:cost]].min
        if github_credit > 0
          project_content[:github_credit] = github_credit
          credits_by_name["GitHub Runner Credit"] = (credits_by_name["GitHub Runner Credit"] || 0.0) + github_credit
          project_content[:cost] -= github_credit
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
          credits_by_name["Free Inference Tokens"] = (credits_by_name["Free Inference Tokens"] || 0.0) + free_inference_tokens_credit
          project_content[:cost] -= free_inference_tokens_credit
        end

        project_content[:credit] = credits_by_name.values.sum.round(3)
        project_content[:credits] = credits_by_name.map { |name, amount| {name:, amount: amount.round(3)} }
        project_content[:cost] = project_content[:cost].round(3)

        if project_content[:cost] < Config.minimum_invoice_charge_threshold
          vat_info = nil
        end
        project_content[:vat_info] = vat_info

        if vat_info && !vat_info[:reversed]
          project_content[:vat_info][:amount] = (project_content[:cost] * vat_info[:rate].fdiv(100)).round(3)
          project_content[:cost] += project_content[:vat_info][:amount]
        end
        project_content[:cost] = project_content[:cost].round(3)
        project_content[:invoice_version] = CURRENT_INVOICE_VERSION

        if @save_result
          invoice_month = @begin_time.strftime("%y%m")
          invoice_customer = project.id[-10..]
          invoice_order = format("%04d", project.invoices.count + 1)
          invoice_number = "#{invoice_month}-#{invoice_customer}-#{invoice_order}"

          invoice = Invoice.create(project_id: project.id, invoice_number:, content: project_content, begin_time: @begin_time, end_time: @end_time)

          # Use dataset update instead of model update because model updates deal with
          # values and this requires an expression.
          resource_credit_consumptions.each do |rc, consumed|
            rc.this.update(amount: Sequel[:amount] - consumed)
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
    active_billing_records = BillingRecord.eager(project: [:invoices, billing_info: :payment_methods])
      .where { |br| Sequel.pg_range(br.span).overlaps(Sequel.pg_range(@begin_time...@end_time)) }
    active_billing_records = active_billing_records.where(project_id: @project_ids) unless @project_ids.empty?

    # We cap the billable duration at 672 hours. In this way, we can
    # charge the users same each month no matter the number of days
    # in that month. When records share a (resource_id, slot) tag — e.g.
    # a Postgres primary that was scaled mid-month produces two records —
    # the cap is applied to their combined duration so transitions don't
    # let a customer exceed 28 days of charges for the same slot.
    groups = active_billing_records.all.group_by do |br|
      slot = br.resource_tags["slot"]
      slot ? [br.resource_id, slot] : br.id
    end

    monthly_cap = 672 * 60
    groups.flat_map do |_, group|
      group_raw_durations = group.map { it.duration(@begin_time, @end_time).ceil }
      group_total_duration = group_raw_durations.sum
      scale_factor = [monthly_cap.fdiv(group_total_duration), 1.0].min
      group.zip(group_raw_durations).map do |br, raw_duration|
        duration = (raw_duration * scale_factor).round
        {
          project: br.project,
          resource_id: br.resource_id,
          location: br.billing_rate["location"],
          resource_name: br.resource_name,
          resource_type: br.billing_rate["resource_type"],
          resource_family: br.billing_rate["resource_family"],
          byoc: br.billing_rate["byoc"],
          amount: br.amount,
          cost: (br.amount * duration * br.billing_rate["unit_price"]).round(3),
          duration:,
          begin_time: br.span.begin,
          unit_price: br.billing_rate["unit_price"],
        }
      end
    end
  end
end
