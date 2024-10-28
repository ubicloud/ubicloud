# frozen_string_literal: true

module CloverBase
  def self.included(base)
    base.extend(ClassMethods)
    base.plugin :all_verbs
    base.plugin :request_headers

    logger = if ENV["RACK_ENV"] == "test"
      Class.new {
        def write(_)
        end
      }.new
    else
      # :nocov:
      $stderr
      # :nocov:
    end
    base.plugin :common_logger, logger
  end

  def current_account
    return @current_account if defined?(@current_account)
    @current_account = Account[rodauth.session_value]
  end

  # Assign some HTTP response codes to common exceptions.
  def parse_error(e)
    case e
    when Sequel::ValidationFailed
      code = 400
      type = "InvalidRequest"
      message = e.to_s
    when CloverError
      code = e.code
      type = e.type
      message = e.message
      details = e.details
    else
      $stderr.print "#{e.class}: #{e.message}\n"
      warn e.backtrace

      code = 500
      type = "UnexceptedError"
      message = "Sorry, we couldn’t process your request because of an unexpected error."
    end

    response.status = code

    {
      code: code,
      type: type,
      message: message,
      details: details
    }
  end

  def fetch_location_based_prices(*resource_types)
    # We use 1 month = 672 hours for conversion. Number of hours
    # in a month changes between 672 and 744, We are  also capping
    # billable hours to 672 while generating invoices. This ensures
    # that users won't see higher price in their invoice compared
    # to price calculator and also we charge same amount no matter
    # the number of days in a given month.
    BillingRate.rates.filter { resource_types.include?(_1["resource_type"]) }
      .group_by { [_1["resource_type"], _1["resource_family"], _1["location"]] }
      .map { |_, brs| brs.max_by { _1["active_from"] } }
      .each_with_object(Hash.new { |h, k| h[k] = h.class.new(&h.default_proc) }) do |br, hash|
      hash[br["location"]][br["resource_type"]][br["resource_family"]] = {
        hourly: br["unit_price"].to_f * 60,
        monthly: br["unit_price"].to_f * 60 * 672
      }
    end
  end

  module ClassMethods
    def autoload_routes(route)
      route_path = "routes/#{route}"
      if Config.production?
        # :nocov:
        Unreloader.require(route_path)
        # :nocov:
      else
        plugin :autoload_hash_branches
        Dir["#{route_path}/**/*.rb"].each do |full_path|
          parts = full_path.delete_prefix("#{route_path}/").split("/")
          namespaces = parts[0...-1]
          filename = parts.last
          if namespaces.empty?
            autoload_hash_branch(File.basename(filename, ".rb").tr("_", "-"), full_path)
          else
            autoload_hash_branch(:"#{namespaces.join("_")}_prefix", File.basename(filename, ".rb").tr("_", "-"), full_path)
          end
        end
        Unreloader.autoload(route_path, delete_hook: proc { |f| hash_branch(File.basename(f, ".rb").tr("_", "-")) }) {}
      end
    end
  end
end
