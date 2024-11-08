# frozen_string_literal: true

require_relative "../model"
require "stripe"
require "prawn"
require "prawn/table"

class Invoice < Sequel::Model
  many_to_one :project

  include ResourceMethods

  def path
    "/invoice/#{id ? ubid : "current"}"
  end

  def name
    begin_time.strftime("%B %Y")
  end

  def charge
    reload # Reload to get the latest status to avoid double charging
    unless (Stripe.api_key = Config.stripe_secret_key)
      Clog.emit("Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing.")
      return true
    end

    if status != "unpaid"
      Clog.emit("Invoice already charged.") { {invoice_already_charged: {ubid: ubid, status: status}} }
      return true
    end

    amount = content["cost"].to_f.round(2)
    if amount < Config.minimum_invoice_charge_threshold
      update(status: "below_minimum_threshold")
      Clog.emit("Invoice cost is less than minimum charge cost.") { {invoice_below_threshold: {ubid: ubid, cost: amount}} }
      send_success_email(below_threshold: true)
      return true
    end

    if (billing_info = BillingInfo[content.dig("billing_info", "id")]).nil? || billing_info.payment_methods.empty?
      Clog.emit("Invoice doesn't have billing info.") { {invoice_no_billing: {ubid: ubid}} }
      return false
    end

    errors = []
    billing_info.payment_methods_dataset.order(:order).each do |pm|
      begin
        payment_intent = Stripe::PaymentIntent.create({
          amount: (amount * 100).to_i, # 100 cents to charge $1.00
          currency: "usd",
          confirm: true,
          off_session: true,
          customer: billing_info.stripe_id,
          payment_method: pm.stripe_id
        })
      rescue Stripe::CardError => e
        Clog.emit("Invoice couldn't charged.") { {invoice_not_charged: {ubid: ubid, payment_method: pm.ubid, error: e.message}} }
        errors << e.message
        next
      end

      unless payment_intent.status == "succeeded"
        Clog.emit("BUG: payment intent should succeed here") { {invoice_not_charged: {ubid: ubid, payment_method: pm.ubid, intent_id: payment_intent.id, error: payment_intent.status}} }
        next
      end

      Clog.emit("Invoice charged.") { {invoice_charged: {ubid: ubid, payment_method: pm.ubid, cost: amount}} }
      self.status = "paid"
      content.merge!({
        "payment_method" => {
          "id" => pm.id,
          "stripe_id" => pm.stripe_id
        },
        "payment_intent" => payment_intent.id
      })
      save(columns: [:status, :content])
      project.update(reputation: "verified") if amount > 5

      send_success_email
      return true
    end

    Clog.emit("Invoice couldn't charged with any payment method.") { {invoice_not_charged: {ubid: ubid}} }
    send_failure_email(errors)
    false
  end

  def send_success_email(below_threshold: false)
    ser = Serializers::Invoice.serialize(self, {detailed: true})
    messages = if below_threshold
      ["Since the invoice total of #{ser[:total]} is below our minimum charge threshold, there will be no charges for this month."]
    else
      ["The invoice amount of #{ser[:total]} will be debited from your credit card on file."]
    end
    github_usage = ser[:items].select { _1[:description].include?("GitHub Runner") }.sum { _1[:cost] }
    saved_amount = 9 * github_usage
    if saved_amount > 1
      messages << "You saved $#{saved_amount.to_i} this month using managed Ubicloud runners instead of GitHub hosted runners!"
    end

    Util.send_email(ser[:billing_email], "Ubicloud #{ser[:name]} Invoice ##{ser[:invoice_number]}",
      greeting: "Dear #{ser[:billing_name]},",
      body: ["Please find your current invoice ##{ser[:invoice_number]} below.",
        *messages,
        "If you have any questions, please send us a support request via support@ubicloud.com, and include your invoice number."],
      button_title: "View Invoice",
      button_link: "#{Config.base_url}#{project.path}/billing#{ser[:path]}",
      attachments: [["#{ser[:filename]}.pdf", generate_pdf(ser)]])
  end

  def send_failure_email(errors)
    ser = Serializers::Invoice.serialize(self, {detailed: true})
    receivers = [ser[:billing_email]]
    receivers += project.accounts.select { Authorization.has_permission?(_1.id, "Project:billing", project.id) }.map(&:email)
    Util.send_email(receivers.uniq, "Urgent: Action Required to Prevent Service Disruption",
      cc: Config.mail_from,
      greeting: "Dear #{ser[:billing_name]},",
      body: ["We hope this message finds you well.",
        "We've noticed that your credit card on file has been declined with the following errors:",
        *errors.map { "- #{_1}" },
        "The invoice amount of #{ser[:total]} tried be debited from your credit card on file.",
        "To prevent service disruption, please update your payment information within the next two days.",
        "If you have any questions, please send us a support request via support@ubicloud.com."],
      button_title: "Update Payment Method",
      button_link: "#{Config.base_url}#{project.path}/billing")
  end

  def generate_pdf(data)
    pdf = Prawn::Document.new(
      page_size: "A4",
      page_layout: :portrait,
      info: {Title: data[:filename], Creator: "Ubicloud", reationDate: created_at}
    )
    # We use external fonts to support all UTF-8 characters
    pdf.font_families.update(
      "BeVietnamPro" => {
        normal: "assets/font/BeVietnamPro/Regular.ttf",
        semibold: "assets/font/BeVietnamPro/SemiBold.ttf"
      }
    )
    pdf.font "BeVietnamPro"

    column_width = (pdf.bounds.width / 2) - 10
    right_column_x = column_width + 20
    dark_gray = "1F2937" # Tailwind text-gray-800
    light_gray = "6B7280" # Tailwind text-gray-500

    pdf.fill_color light_gray

    # Row 1, Left Column: Logo and issuer information
    row_y = pdf.bounds.top
    row = pdf.bounding_box([0, row_y], width: column_width) do
      path = "public/logo-primary.png"
      pdf.image path, height: 25, position: :left
      pdf.move_down 10
      # :nocov:
      pdf.text data[:issuer_name], style: :semibold, color: dark_gray if data[:issuer_name]
      # :nocov:
      pdf.text "#{data[:issuer_address]},"
      pdf.text "#{data[:issuer_city]}, #{data[:issuer_state]} #{data[:issuer_postal_code]},"
      pdf.text data[:issuer_country]
    end

    # Row 1, Right Column: Invoice name and number
    pdf.bounding_box([right_column_x, row_y], width: column_width) do
      pdf.text "Invoice for #{data[:name]}", align: :right, style: :semibold, color: dark_gray, size: 18
      pdf.text "##{data[:invoice_number]}", align: :right
    end
    pdf.move_down row.height.to_i - 20

    # Row 2, Left Column: Billing information
    row_y = pdf.cursor
    row = pdf.bounding_box([0, row_y], width: column_width) do
      pdf.text "Bill to:", style: :semibold, color: dark_gray, size: 14
      pdf.text [data[:billing_name], data[:company_name]].compact.join(" - "), style: :semibold, color: dark_gray, size: 14
      pdf.move_down 5
      # :nocov:
      pdf.text "Tax ID: #{data[:tax_id]}" if data[:tax_id]
      # :nocov:
      pdf.text "#{data[:billing_address]},"
      pdf.text "#{data[:billing_city]}, #{data[:billing_state]} #{data[:billing_postal_code]},"
      pdf.text data[:billing_country]
    end

    # Row 2, Right Column: Invoice dates
    pdf.bounding_box([right_column_x, row_y], width: column_width) do
      dates = [["Invoice date:", data[:date]], ["Due date:", data[:date]]]
      pdf.table(dates, position: :right) do
        style(row(0..1).columns(0..1), padding: [2, 5, 2, 5], borders: [])
        style(column(0), align: :right, font_style: :semibold, text_color: dark_gray)
        style(column(1), align: :right)
      end
    end
    pdf.move_down row.height.to_i - 20

    # Row 3: Invoice items
    items = [["RESOURCE", "DESCRIPTION", "USAGE", "AMOUNT"]]
    items += if data[:items].empty?
      [[{content: "No resources", colspan: 4, align: :center, font_style: :semibold}]]
    else
      data[:items].map { [_1[:name], _1[:description], _1[:usage], _1[:cost_humanized]] }
    end
    pdf.table items, header: true, width: pdf.bounds.width, cell_style: {size: 9, border_color: "E5E7EB", borders: [], padding: [5, 6, 12, 6], valign: :center} do
      style(row(0), size: 12, font_style: :semibold, text_color: dark_gray, background_color: "F9FAFB")
      style(column(0), text_color: dark_gray)
      style(columns(-2..-1), align: :right)
      style(column(0), borders: [:left, :top, :bottom])
      style(column(-1), borders: [:right, :top, :bottom], width: 70)
      style(columns(1..-2), borders: [:top, :bottom])
    end
    pdf.move_down 10

    # Row 4: Totals
    totals = [
      ["Subtotal:", data[:subtotal]],
      # :nocov:
      (data[:discount] != "$0.00") ? ["Discount:", "-#{data[:discount]}"] : nil,
      (data[:credit] != "$0.00") ? ["Credit:", "-#{data[:credit]}"] : nil,
      # :nocov:
      ["Total:", data[:total]]
    ].compact
    pdf.table(totals, position: :right, cell_style: {padding: [2, 5, 2, 5], borders: []}) do
      style(column(0), align: :right, font_style: :semibold, text_color: dark_gray)
      style(column(1), align: :right)
    end

    pdf.render
  end
end

Invoice.unrestrict_primary_key

# Table: invoice
# Columns:
#  id             | uuid                     | PRIMARY KEY
#  project_id     | uuid                     | NOT NULL
#  content        | jsonb                    | NOT NULL
#  created_at     | timestamp with time zone | NOT NULL DEFAULT now()
#  invoice_number | text                     | NOT NULL
#  begin_time     | timestamp with time zone | NOT NULL
#  end_time       | timestamp with time zone | NOT NULL
#  status         | text                     | NOT NULL DEFAULT 'unpaid'::text
# Indexes:
#  invoice_pkey             | PRIMARY KEY btree (id)
#  invoice_project_id_index | btree (project_id)
