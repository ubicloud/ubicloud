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
        view "project/billing"
      end

      r.post true do
        if (billing_info = @project.billing_info)
          handle_validation_failure("project/billing")
          current_tax_id = billing_info.stripe_data["tax_id"]
          tp = typecast_params
          new_tax_id = tp.str!("tax_id").gsub(/[^a-zA-Z0-9]/, "")

          begin
            Stripe::Customer.update(billing_info.stripe_id, {
              name: tp.str!("name"),
              email: tp.str!("email").strip,
              address: {
                country: tp.str!("country"),
                state: tp.str!("state"),
                city: tp.str!("city"),
                postal_code: tp.str!("postal_code"),
                line1: tp.str!("address"),
                line2: nil
              },
              metadata: {
                tax_id: new_tax_id,
                company_name: tp.str!("company_name")
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
            raise_web_error(e.message)
          end

          flash["notice"] = "Billing info updated"
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
        handle_validation_failure("project/billing")
        checkout_session = Stripe::Checkout::Session.retrieve(typecast_params.str!("session_id"))
        setup_intent = Stripe::SetupIntent.retrieve(checkout_session["setup_intent"])

        stripe_id = setup_intent["payment_method"]
        stripe_payment_method = Stripe::PaymentMethod.retrieve(stripe_id)
        card_fingerprint = stripe_payment_method["card"]["fingerprint"]
        unless PaymentMethod.where(fraud: true, card_fingerprint:).empty?
          raise_web_error("Payment method you added is labeled as fraud. Please contact support.")
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
          raise_web_error("We couldn't pre-authorize your card for verification. Please make sure it can be pre-authorized up to $5 or contact our support team at support@ubicloud.com.")
        end

        DB.transaction do
          unless (billing_info = @project.billing_info)
            billing_info = BillingInfo.create(stripe_id: customer_stripe_id)
            @project.update(billing_info_id: billing_info.id)
          end

          PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: stripe_id, card_fingerprint: card_fingerprint, preauth_intent_id: payment_intent.id, preauth_amount: preauth_amount)
        end

        unless @project.billing_info.has_address?
          Stripe::Customer.update(@project.billing_info.stripe_id, {
            address: stripe_payment_method["billing_details"]["address"].to_hash
          })
        end

        flash["notice"] = "Billing info updated"
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

        r.delete :ubid_uuid do |id|
          next unless (payment_method = PaymentMethod[id:, billing_info_id: @project.billing_info_id])

          unless payment_method.billing_info.payment_methods_dataset.count > 1
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

      r.get "invoice", ["current", :ubid_uuid] do |id|
        next unless (invoice = (id == "current") ? @project.current_invoice : Invoice[id:, project_id: @project.id])

        @invoice_data = Serializers::Invoice.serialize(invoice, {detailed: true})

        if invoice.status == "current"
          view "project/invoice"
        else
          response["content-type"] = "application/pdf"
          response["content-disposition"] = "inline; filename=\"#{invoice.filename}\""
          begin
            Invoice.blob_storage_client.get_object(bucket: Config.invoices_bucket_name, key: invoice.blob_key).body.read
          rescue Aws::S3::Errors::NoSuchKey
            Clog.emit("Could not find the invoice") { {not_found_invoice: {invoice_ubid: invoice.ubid}} }
            invoice.generate_pdf(@invoice_data)
          end
        end
      end
    end
  end
end
