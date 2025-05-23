# frozen_string_literal: true

require_relative "../model"
require "aws-sdk-s3"
require "countries"
require "prawn"
require "prawn/table"
require "stripe"

class Invoice < Sequel::Model
  unrestrict_primary_key

  many_to_one :project

  plugin ResourceMethods

  def path
    "/invoice/#{id ? ubid : "current"}"
  end

  def filename
    "Ubicloud-#{begin_time.strftime("%Y-%m")}-#{invoice_number}.pdf"
  end

  def blob_key
    group = if status == "below_minimum_threshold"
      "below_minimum_threshold"
    elsif content.dig("vat_info", "reversed")
      "eu_vat_reversed"
    else
      country = ISO3166::Country.new(content.dig("billing_info", "country"))
      if country.alpha2 == "NL"
        "nl"
      elsif country.in_eu_vat?
        "eu"
      else
        "non_eu"
      end
    end
    "#{begin_time.strftime("%Y/%m")}/#{group}/#{filename}"
  end

  def after_destroy
    super
    begin
      Invoice.blob_storage_client.delete_object(bucket: Config.invoices_bucket_name, key: blob_key)
    rescue Aws::S3::Errors::NoSuchKey
    end
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
    billing_info.payment_methods.each do |pm|
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
    pdf = generate_pdf(ser)
    unless ser[:billing_email]
      Clog.emit("Couldn't send the invoice because it has no billing information") { {invoice_no_billing_info: {ubid:}} }
      return
    end
    persist(pdf)
    messages = if below_threshold
      ["Since the invoice total of #{ser[:total]} is below our minimum charge threshold, there will be no charges for this month."]
    else
      ["The invoice amount of #{ser[:total]} will be debited from your credit card on file."]
    end
    github_usage = ser[:items].select { it[:description].include?("GitHub Runner") }.sum { it[:cost] }
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
      attachments: [[filename, pdf]])
  end

  def send_failure_email(errors)
    ser = Serializers::Invoice.serialize(self, {detailed: true})
    receivers = [ser[:billing_email]]
    receivers += project.accounts.select { Authorization.has_permission?(project.id, it.id, "Project:billing", project.id) }.map(&:email)
    Util.send_email(receivers.uniq, "Urgent: Action Required to Prevent Service Disruption",
      cc: Config.mail_from,
      greeting: "Dear #{ser[:billing_name]},",
      body: ["We hope this message finds you well.",
        "We've noticed that your credit card on file has been declined with the following errors:",
        *errors.map { "- #{it}" },
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
      info: {Title: filename, Creator: "Ubicloud", CreationDate: created_at}
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
      pdf.text data[:issuer_name], style: :semibold, color: dark_gray if data[:issuer_name]
      pdf.text "#{data[:issuer_address]},"
      pdf.text "#{data[:issuer_city]}, #{data[:issuer_state]} #{data[:issuer_postal_code]},"
      pdf.text data[:issuer_country]
      pdf.text "#{data[:issuer_in_eu_vat] ? "VAT" : "Tax"} ID: #{data[:issuer_tax_id]}" if data[:issuer_tax_id]
      pdf.text "CCI/KVK ID: #{data[:issuer_trade_id]}" if data[:issuer_trade_id]
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
      if data[:billing_name]
        pdf.text "Bill to:", style: :semibold, color: dark_gray, size: 14
        pdf.text data[:company_name].to_s.strip.empty? ? data[:billing_name] : data[:company_name], style: :semibold, color: dark_gray, size: 14
        pdf.move_down 5
        pdf.text "#{data[:billing_address]},"
        pdf.text "#{data[:billing_city]}, #{data[:billing_state]} #{data[:billing_postal_code]},"
        pdf.text data[:billing_country]
        pdf.text "#{data[:billing_in_eu_vat] ? "VAT" : "Tax"} ID: #{data[:tax_id]}" if data[:tax_id]
      end
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
      data[:items].map { [it[:name], it[:description], it[:usage], it[:cost_humanized]] }
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
      (data[:free_inference_tokens_credit] != "$0.00") ? ["Free Inference Tokens:", "-#{data[:free_inference_tokens_credit]}"] : nil,
      # :nocov:
      if data[:vat_amount] != "$0.00"
        ["VAT (#{data[:vat_rate]}%):", "(#{data[:vat_amount_eur]}) #{data[:vat_amount]}"]
      end,
      (data[:total] != "$0.00" && data[:vat_reversed]) ? [{content: "VAT subject to reverse charge", colspan: 2}] : nil,
      ["Total:", data[:total]]
    ].compact
    pdf.table(totals, position: :right, cell_style: {padding: [2, 5, 2, 5], borders: []}) do
      style(column(0), align: :right, font_style: :semibold, text_color: dark_gray)
      style(column(1), align: :right)
    end

    pdf.render
  end

  def persist(pdf)
    Invoice.blob_storage_client.put_object(
      bucket: Config.invoices_bucket_name,
      key: blob_key,
      body: pdf,
      content_type: "application/pdf",
      if_none_match: "*"
    )
  end

  def self.blob_storage_client
    Aws::S3::Client.new(
      endpoint: Config.invoices_blob_storage_endpoint,
      access_key_id: Config.invoices_blob_storage_access_key,
      secret_access_key: Config.invoices_blob_storage_secret_key,
      region: "auto",
      request_checksum_calculation: "when_required",
      response_checksum_validation: "when_required"
    )
  end
end

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
