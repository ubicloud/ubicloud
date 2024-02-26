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

    # :nocov:
    case Config.mail_driver
    when :smtp
      ::Mail.defaults do
        delivery_method :smtp, {
          address: Config.smtp_hostname,
          port: Config.smtp_port,
          user_name: Config.smtp_user,
          password: Config.smtp_password,
          authentication: :plain,
          enable_starttls: Config.smtp_tls
        }
      end
    when :logger
      ::Mail.defaults do
        delivery_method :logger
      end
    when :test
      ::Mail.defaults do
        delivery_method :test
      end
    end
    # :nocov:
  end

  # Assign some HTTP response codes to common exceptions.
  def parse_error(e)
    case e
    when Sequel::ValidationFailed
      code = 400
      title = "Invalid request"
      message = e.to_s
    when Roda::RodaPlugins::RouteCsrf::InvalidToken
      code = 419
      title = "Invalid Security Token"
      message = "An invalid security token was submitted with this request, and this request could not be processed."
    when CloverError
      code = e.code
      title = e.title
      message = e.message
      details = e.details
    else
      $stderr.print "#{e.class}: #{e.message}\n"
      warn e.backtrace

      code = 500
      title = "Unexcepted Error"
      message = "Sorry, we couldn’t process your request because of an unexpected error."
    end

    response.status = code

    {
      code: code,
      title: title,
      message: message,
      details: details
    }
  end

  def serialize(data, structure = :default)
    @serializer.new(structure).serialize(data)
  end

  def send_email(receiver, subject, greeting: nil, body: nil, button_title: nil, button_link: nil)
    html = render "/email/layout", locals: {subject: subject, greeting: greeting, body: body, button_title: button_title, button_link: button_link}
    Mail.deliver do
      from Config.mail_from
      to receiver
      subject subject

      text_part do
        body "#{greeting}\n#{Array(body).join("\n")}\n#{button_link}"
      end

      html_part do
        content_type "text/html; charset=UTF-8"
        body html
      end
    end
  end

  def fetch_location_based_prices(*resource_types)
    # We use 1 month = 672 hours for conversion. Number of hours
    # in a month changes between 672 and 744, We are  also capping
    # billable hours to 672 while generating invoices. This ensures
    # that users won't see higher price in their invoice compared
    # to price calculator and also we charge same amount no matter
    # the number of days in a given month.
    BillingRate.rates.filter { resource_types.include?(_1["resource_type"]) }
      .each_with_object(Hash.new { |h, k| h[k] = h.class.new(&h.default_proc) }) do |br, hash|
      hash[br["location"]][br["resource_type"]][br["resource_family"]] = {
        hourly: br["unit_price"].to_f * 60,
        monthly: br["unit_price"].to_f * 60 * 672
      }
    end
  end

  def base_url
    # :nocov:
    port = ":#{request.port}" if request.port != Rack::Request::DEFAULT_PORTS[request.scheme]
    # :nocov:
    "#{request.scheme}://#{request.host}#{port}"
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
