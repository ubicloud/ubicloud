# frozen_string_literal: true

require "stripe"
require "countries"

class CloverWeb
  hash_branch(:project_prefix, "billing") do |r|
    unless (Stripe.api_key = Config.stripe_secret_key)
      response.status = 501
      return "Billing is not enabled. Set STRIPE_SECRET_KEY to enable billing."
    end

    Authorization.authorize(@current_user.id, "Project:billing", @project.id)

    r.get true do
      if (billing_info = @project.billing_info)
        @billing_info_data = Serializers::Web::BillingInfo.serialize(billing_info)
        @payment_methods = Serializers::Web::PaymentMethod.serialize(billing_info.payment_methods)
        @invoices = Serializers::Web::Invoice.serialize(@project.invoices.prepend(@project.current_invoice))
      end

      view "project/billing"
    end

    r.post true do
      if (billing_info = @project.billing_info)
        Stripe::Customer.update(billing_info.stripe_id, {
          name: r.params["name"],
          email: r.params["email"],
          address: {
            country: r.params["country"],
            state: r.params["state"],
            city: r.params["city"],
            postal_code: r.params["postal_code"],
            line1: r.params["address"],
            line2: nil
          },
          metadata: {
            tax_id: r.params["tax_id"],
            company_name: r.params["company_name"]
          }
        })

        return r.redirect @project.path + "/billing"
      end

      checkout = Stripe::Checkout::Session.create(
        payment_method_types: ["card"],
        mode: "setup",
        customer_creation: "always",
        billing_address_collection: "required",
        success_url: "#{base_url}#{@project.path}/billing/success?session_id={CHECKOUT_SESSION_ID}",
        cancel_url: "#{base_url}#{@project.path}/billing"
      )

      r.redirect checkout.url, 303
    end

    r.get "success" do
      checkout_session = Stripe::Checkout::Session.retrieve(r.params["session_id"])
      setup_intent = Stripe::SetupIntent.retrieve(checkout_session["setup_intent"])

      DB.transaction do
        unless (billing_info = @project.billing_info)
          billing_info = BillingInfo.create_with_id(stripe_id: setup_intent["customer"])
          @project.update(billing_info_id: billing_info.id)
        end

        PaymentMethod.create_with_id(billing_info_id: billing_info.id, stripe_id: setup_intent["payment_method"])
      end

      r.redirect @project.path + "/billing"
    end

    r.on "payment-method" do
      r.get "create" do
        unless (billing_info = @project.billing_info)
          response.status = 404
          r.halt
        end

        checkout = Stripe::Checkout::Session.create(
          payment_method_types: ["card"],
          mode: "setup",
          customer: billing_info.stripe_id,
          success_url: "#{base_url}#{@project.path}/billing/success?session_id={CHECKOUT_SESSION_ID}",
          cancel_url: "#{base_url}#{@project.path}/billing"
        )

        r.redirect checkout.url, 303
      end

      r.is String do |pm_ubid|
        payment_method = PaymentMethod.from_ubid(pm_ubid)

        unless payment_method
          response.status = 404
          r.halt
        end

        r.delete true do
          unless payment_method.billing_info.payment_methods.count > 1
            response.status = 400
            return {message: "You can't delete the last payment method of a project."}.to_json
          end

          payment_method.destroy

          return {message: "Deleting #{payment_method.ubid}"}.to_json
        end
      end
    end

    r.on "invoice" do
      r.is String do |invoice_ubid|
        @serializer = Serializers::Web::Invoice

        invoice = (invoice_ubid == "current") ? @project.current_invoice : Invoice.from_ubid(invoice_ubid)

        unless invoice
          response.status = 404
          r.halt
        end

        r.get true do
          @full_page = r.params["print"] == "1"
          @invoice_data = serialize(invoice, :detailed)
          view "project/invoice"
        end
      end
    end
  end
end
