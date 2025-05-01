# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "discount-code") do |r|
    r.web do
      authorize("Project:billing", @project.id)
      billing_path = "#{@project.path}/billing"

      r.post true do
        discount_code = r.params["discount_code"].to_s.strip.downcase
        Validation.validate_short_text(discount_code, "discount_code")

        # Check if the discount code exists
        discount = DiscountCode.first(code: discount_code) { expires_at > Time.now.utc }
        unless discount
          flash["error"] = "Discount code not found."
          Clog.emit("Invalid discount code attempted") { {invalid_discount_code: {project_id: @project.id, code: discount_code}} }
          r.redirect billing_path
        end

        begin
          DB.transaction do
            ProjectDiscountCode.insert(
              id: ProjectDiscountCode.generate_uuid,
              project_id: @project.id,
              discount_code_id: discount.id
            )
            @project.this.update(credit: Sequel[:credit] + discount.credit_amount.to_f)
          end
        rescue Sequel::UniqueConstraintViolation
          flash["error"] = "Discount code has already been applied to this project."
        else
          flash["notice"] = "Discount code successfully applied."
        end

        r.redirect billing_path
      end
    end
  end
end
