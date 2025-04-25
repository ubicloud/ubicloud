# frozen_string_literal: true

class Clover < Roda
  PG_STATE_LABEL_COLOR = Hash.new("bg-slate-100 text-slate-800").merge!(
    "running" => "bg-green-100 text-green-800",
    "creating" => "bg-yellow-100 text-yellow-800",
    "deleting" => "bg-red-100 text-red-800"
  ).freeze

  PS_STATE_LABEL_COLOR = Hash.new("bg-yellow-100 text-yellow-80").merge!(
    "available" => "bg-green-100 text-green-800"
  ).freeze

  KUBERNETES_STATE_LABEL_COLOR = Hash.new("bg-slate-100 text-slate-800").merge!(
    "running" => "bg-green-100 text-green-800",
    "creating" => "bg-yellow-100 text-yellow-800",
    "deleting" => "bg-red-100 text-red-800"
  ).freeze

  VM_STATE_LABEL_COLOR = Hash.new("bg-slate-100 text-slate-800").merge!(
    "running" => "bg-green-100 text-green-800",
    "creating" => "bg-yellow-100 text-yellow-800",
    "deleting" => "bg-red-100 text-red-800"
  )
  ["rebooting", "starting", "waiting for capacity", "restarting"].each do
    VM_STATE_LABEL_COLOR[it] = VM_STATE_LABEL_COLOR["creating"]
  end
  VM_STATE_LABEL_COLOR["deleted"] = VM_STATE_LABEL_COLOR["deleting"]
  VM_STATE_LABEL_COLOR.freeze

  BUTTON_COLOR = Hash.new { |h, k| raise "unsupported button type: #{k}" }.merge!(
    "primary" => "bg-orange-600 hover:bg-orange-700 focus-visible:outline-orange-600",
    "danger" => "bg-rose-600 hover:bg-rose-700 focus-visible:outline-rose-600"
  ).freeze

  PG_HA_DATA = {
    PostgresResource::HaType::NONE => "Inactive",
    PostgresResource::HaType::ASYNC => "Active (1 standby with asynchronous replication)",
    PostgresResource::HaType::SYNC => "Active (2 standbys with synchronous replication)"
  }.freeze

  def csrf_tag(*)
    part("components/form/hidden", name: csrf_field, value: csrf_token(*))
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

      rack_response = Clover.call(env.merge("REQUEST_METHOD" => "GET", "PATH_INFO" => uri.path, "rack.input" => StringIO.new("".b), "rack.request.form_input" => nil, "rack.request.form_hash" => nil))
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

  def sort_aces!(aces)
    @aces.sort! do |a, b|
      # :nocov:
      # Admin tag at the top (one of these branches will be hit, but
      # cannot force which)
      next -1 unless a.last
      next 1 unless b.last
      # :nocov:
      # Label sorting by subject, action, object for remaining ACEs
      a_tags = a[1]
      b_tags = b[1]
      x = nil
      a_tags.each_with_index do |v, i|
        x = ace_label(v) <=> ace_label(b_tags[i])
        break unless x.nil? || x.zero?
      end
      next x unless x.nil? || x.zero?
      # Tie break using ubid
      a[0] <=> b[0]
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
    when ObjectMetatag
      "ObjectTag: #{obj.name}"
    when ApiKey
      "InferenceApiKey: #{obj.name}"
    else
      "#{obj.class.name}: #{obj.name}"
    end
  end

  def object_tag_membership_label(obj)
    case obj
    when ObjectTag
      "Tag: #{obj.name}"
    when ObjectMetatag
      "ObjectTag: #{obj.name}"
    when ApiKey
      "InferenceApiKey: #{obj.name}"
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
