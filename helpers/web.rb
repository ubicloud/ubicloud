# frozen_string_literal: true

class Clover < Roda
  def csrf_tag(*)
    render("components/form/hidden", locals: {name: csrf_field, value: csrf_token(*)})
  end

  def redirect_back_with_inputs
    referrer = flash["referrer"] || env["HTTP_REFERER"]
    uri = begin
      Kernel.URI(referrer)
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    request.redirect "/" unless uri

    flash["old"] = request.params

    if uri && env["REQUEST_METHOD"] != "GET"
      # Force flash rotation, so flash works correctly for internal redirects
      _roda_after_40__flash(nil)

      rack_response = Clover.call(env.merge("REQUEST_METHOD" => "GET", "PATH_INFO" => uri.path))
      flash.discard
      flash["referrer"] = referrer
      env.delete("roda.session.serialized")
      rack_response[0] = response.status || 400
      request.halt rack_response
    else
      request.redirect referrer
    end
  end

  def omniauth_providers
    @omniauth_providers ||= [
      # :nocov:
      Config.omniauth_google_id ? [:google, "Google"] : nil,
      Config.omniauth_github_id ? [:github, "GitHub"] : nil
      # :nocov:
    ].compact
  end
end
