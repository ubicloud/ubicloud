# frozen_string_literal: true

class Clover < Roda
  def csrf_tag(*)
    render("components/form/hidden", locals: {name: csrf_field, value: csrf_token(*)})
  end

  def redirect_back_with_inputs
    flash["old"] = request.params
    request.redirect env["HTTP_REFERER"] || "/"
  end
end
