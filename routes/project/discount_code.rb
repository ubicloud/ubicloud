# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "discount-code") do |r|
    r.post r.web? do
      authorize("Project:billing", @project.id)
      handle_validation_failure("project/billing")
      billing_path = "#{@project.path}/billing"

      if (discount_code = typecast_params.nonempty_str("discount_code"))
        discount_code = discount_code.strip.downcase
        Validation.validate_short_text(discount_code, "discount_code")

        # Check if the discount code exists
        discount = DiscountCode.first(code: discount_code) { expires_at > Sequel::CURRENT_TIMESTAMP }
      end

      unless discount
        Clog.emit("Invalid discount code attempted") { {invalid_discount_code: {project_id: @project.id, code: discount_code}} }
        raise CloverError.new(400, nil, "Discount code not found.")
      end

      begin
        DB.transaction do
          hash = ProjectDiscountCode.dataset.returning.insert(
            id: ProjectDiscountCode.generate_uuid,
            project_id: @project.id,
            discount_code_id: discount.id
          ).first
          @project.this.update(credit: Sequel[:credit] + discount.credit_amount.to_f)
          audit_log(ProjectDiscountCode.call(hash), "create")
        end
      rescue Sequel::UniqueConstraintViolation
        raise CloverError.new(400, nil, "Discount code has already been applied to this project.")
      end

      unless @project.billing_info
        stripe_customer = Stripe::Customer.create(name: current_account.name, email: current_account.email)
        DB.transaction do
          billing_info = BillingInfo.create(stripe_id: stripe_customer["id"])
          @project.update(billing_info_id: billing_info.id)
        end
      end

      flash["notice"] = "Discount code successfully applied."
      r.redirect billing_path
    end
  end
end
