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

  def ace_label(obj)
    case obj
    when nil
      "All"
    when ActionType
      obj.name
    when ActionTag
      "#{"Global " unless obj.project_id}Tag: #{obj.name}"
    when ObjectTag, SubjectTag
      "Tag: #{obj.name}"
    else
      "#{obj.class.name}: #{obj.name}"
    end
  end

  def check_ace_subject(subject)
    # Do not allow personal access tokens as subjects
    # Do not allow modifiction or addition of an ace entry with the Admin subject,
    # which is reserved for full access.
    if UBID.uuid_class_match?(subject, ApiKey) ||
        UBID.uuid_class_match?(subject, SubjectTag) && SubjectTag[subject].name == "Admin"
      raise Authorization::Unauthorized
    end
  end
end
