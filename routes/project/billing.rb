# frozen_string_literal: true

require "stripe"
require "countries"

class Clover
  hash_branch(:project_prefix, "billing") do |r|
    r.web do
      unless (Stripe.api_key = Config.stripe_secret_key)
        response.status = 501
        response["content-type"] = "text/plain"
        next "Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing."
      end

      authorize("Project:billing", @project.id)

      r.get true do
        if @project.billing_info
          @invoices = Serializers::Invoice.serialize(@project.invoices.prepend(@project.current_invoice))
        end

        @usage_alerts = Serializers::UsageAlert.serialize(@project.usage_alerts_dataset.eager(:user))

        view "project/billing"
      end

      r.post true do
        if (billing_info = @project.billing_info)
          current_tax_id = billing_info.stripe_data["tax_id"]
          new_tax_id = r.params["tax_id"].gsub(/[^a-zA-Z0-9]/, "")
          begin
            Stripe::Customer.update(billing_info.stripe_id, {
              name: r.params["name"],
              email: r.params["email"].strip,
              address: {
                country: r.params["country"],
                state: r.params["state"],
                city: r.params["city"],
                postal_code: r.params["postal_code"],
                line1: r.params["address"],
                line2: nil
              },
              metadata: {
                tax_id: new_tax_id,
                company_name: r.params["company_name"]
              }
            })
            if new_tax_id != current_tax_id
              DB.transaction do
                billing_info.update(valid_vat: nil)
                if new_tax_id && billing_info.country&.in_eu_vat?
                  Strand.create(prog: "ValidateVat", label: "start", stack: [{subject_id: billing_info.id}])
                end
              end
            end
            audit_log(@project, "update_billing")
          rescue Stripe::InvalidRequestError => e
            flash["error"] = e.message
          end

          r.redirect @project.path + "/billing"
        else
          no_audit_log
        end

        checkout = Stripe::Checkout::Session.create(
          payment_method_types: ["card"],
          mode: "setup",
          customer_creation: "always",
          billing_address_collection: "required",
          success_url: "#{Config.base_url}#{@project.path}/billing/success?session_id={CHECKOUT_SESSION_ID}",
          cancel_url: "#{Config.base_url}#{@project.path}/billing"
        )

        r.redirect checkout.url, 303
      end

      r.get "success" do
        checkout_session = Stripe::Checkout::Session.retrieve(r.params["session_id"])
        setup_intent = Stripe::SetupIntent.retrieve(checkout_session["setup_intent"])

        stripe_id = setup_intent["payment_method"]
        stripe_payment_method = Stripe::PaymentMethod.retrieve(stripe_id)
        card_fingerprint = stripe_payment_method["card"]["fingerprint"]
        if PaymentMethod.where(fraud: true).select_map(:card_fingerprint).include?(card_fingerprint)
          flash["error"] = "Payment method you added is labeled as fraud. Please contact support."
          r.redirect @project.path + "/billing"
        end

        # Pre-authorize card to check if it is valid, if so
        # authorization won't be captured and will be refunded immediately
        begin
          customer_stripe_id = setup_intent["customer"]

          # Pre-authorizing random amount to verify card. As it is
          # commonly done with other companies, apparently it is
          # better to detect fraud then pre-authorizing fixed amount.
          # That money will be kept until next billing period and if
          # it's not a fraud, it will be applied to the invoice.
          preauth_amount = [100, 200, 300, 400, 500].sample
          payment_intent = Stripe::PaymentIntent.create({
            amount: preauth_amount,
            currency: "usd",
            confirm: true,
            off_session: true,
            capture_method: "manual",
            customer: customer_stripe_id,
            payment_method: stripe_id
          })

          if payment_intent.status != "requires_capture"
            raise "Authorization failed"
          end
        rescue
          # Log and redirect if Stripe card error or our manual raise
          Clog.emit("Couldn't pre-authorize card") { {card_authorization: {project_id: @project.id, customer_stripe_id: customer_stripe_id}} }
          flash["error"] = "We couldn't pre-authorize your card for verification. Please make sure it can be pre-authorized up to $5 or contact our support team at support@ubicloud.com."
          r.redirect @project.path + "/billing"
        end

        DB.transaction do
          unless (billing_info = @project.billing_info)
            billing_info = BillingInfo.create_with_id(stripe_id: customer_stripe_id)
            @project.update(billing_info_id: billing_info.id)
          end

          PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: stripe_id, card_fingerprint: card_fingerprint, preauth_intent_id: payment_intent.id, preauth_amount: preauth_amount)
        end

        if !@project.billing_info.has_address?
          Stripe::Customer.update(@project.billing_info.stripe_id, {
            address: stripe_payment_method["billing_details"]["address"].to_hash
          })
        end

        r.redirect @project.path + "/billing"
      end

      r.on "payment-method" do
        r.get "create" do
          next unless (billing_info = @project.billing_info)

          checkout = Stripe::Checkout::Session.create(
            payment_method_types: ["card"],
            mode: "setup",
            customer: billing_info.stripe_id,
            billing_address_collection: billing_info.has_address? ? "auto" : "required",
            success_url: "#{Config.base_url}#{@project.path}/billing/success?session_id={CHECKOUT_SESSION_ID}",
            cancel_url: "#{Config.base_url}#{@project.path}/billing"
          )

          r.redirect checkout.url, 303
        end

        r.is String do |pm_ubid|
          next unless (payment_method = PaymentMethod[:id => UBID.to_uuid(pm_ubid), :billing_info_id => @project.billing_info_id, Sequel[:billing_info_id] => Sequel::NOTNULL])

          r.delete true do
            unless payment_method.billing_info.payment_methods.count > 1
              response.status = 400
              next {error: {message: "You can't delete the last payment method of a project."}}
            end

            DB.transaction do
              payment_method.destroy
              audit_log(payment_method, "destroy")
            end

            204
          end
        end
      end

      r.on "invoice" do
        r.is String do |invoice_ubid|
          invoice = (invoice_ubid == "current") ? @project.current_invoice : Invoice.from_ubid(invoice_ubid)

          next unless invoice && invoice.project_id == @project.id

          r.get true do
            @invoice_data = Serializers::Invoice.serialize(invoice, {detailed: true})

            unless invoice.status == "current"
              response["content-type"] = "application/pdf"
              response["content-disposition"] = "inline; filename=\"#{invoice.filename}\""
              begin
                next Invoice.blob_storage_client.get_object(bucket: Config.invoices_bucket_name, key: invoice.blob_key).body.read
              rescue Aws::S3::Errors::NoSuchKey
                Clog.emit("Could not find the invoice") { {not_found_invoice: {invoice_ubid: invoice.ubid}} }
                next invoice.generate_pdf(@invoice_data)
              end
            end

            view "project/invoice"
          end
        end
      end
    end
  end
end
