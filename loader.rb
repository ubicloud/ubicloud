# frozen_string_literal: true

require_relative "lib/thread_printer"
Signal.trap("QUIT") do
  ThreadPrinter.run
  Kernel.exit!(Signal.list["QUIT"] + 128)
end

require "bundler/setup"
Bundler.setup

require_relative "config"
require "mail"
require "rack/unreloader"

REPL = false unless defined? REPL

Unreloader = Rack::Unreloader.new(reload: Config.development?, autoload: true) { Clover }

Unreloader.autoload("#{__dir__}/db.rb") { "DB" }
Unreloader.autoload("#{__dir__}/ubid.rb") { "UBID" }

AUTOLOAD_CONSTANTS = ["DB", "UBID"]

# Set up autoloads using Unreloader using a style much like Zeitwerk:
# directories are modules, file names are classes.
autoload_normal = ->(subdirectory, include_first: false, flat: false) do
  absolute = File.join(__dir__, subdirectory)
  rgx = if flat
    # No matter how deep the file system traversal, this Regexp
    # only matches the filename in its capturing group,
    # i.e. it's like File.basename.
    Regexp.new('\A.*?([^/]*)\.rb\z')
  else
    # Capture the relative path of a traversed file, by using
    # Regexp.escape on the prefix that should *not* be
    # interpreted as modules/namespaces.  Since this is works on
    # absolute paths, the ignored content will often be like
    # "/home/myuser/..."
    Regexp.new('\A' + Regexp.escape((File.file?(absolute) ? File.dirname(absolute) : absolute) + "/") + '(.*)\.rb\z')
  end
  last_namespace = nil

  # Copied from sequel/model/inflections.rb's camelize, to convert
  # file paths into module and class names.
  camelize = ->(s) do
    s.gsub(/\/(.?)/) { |x| "::#{x[-1..].upcase}" }.gsub(/(^|_)(.)/) { |x| x[-1..].upcase }
  end

  Unreloader.autoload(absolute) do |f|
    full_name = camelize.call((include_first ? subdirectory + File::SEPARATOR : "") + rgx.match(f)[1])
    parts = full_name.split("::")
    namespace = parts[0..-2].freeze

    # Skip namespace traversal if the last namespace handled has the
    # same components, forming a fast-path that works well when output
    # is the result of a depth-first traversal of the file system, as
    # is normally the case.
    unless namespace == last_namespace
      scope = Object
      namespace.each { |nested|
        scope = if scope.const_defined?(nested, false)
          scope.const_get(nested, false)
        else
          Module.new.tap { scope.const_set(nested, _1) }
        end
      }
      last_namespace = namespace
    end

    # Reloading re-executes this block, which will crash on the
    # subsequently frozen AUTOLOAD_CONSTANTS.  It's also undesirable
    # to have re-additions to the array.
    AUTOLOAD_CONSTANTS << full_name unless AUTOLOAD_CONSTANTS.frozen?

    full_name
  end
end

autoload_normal.call("model", flat: true)
%w[lib clover.rb clover_web.rb clover_api.rb routes/clover_base.rb routes/clover_error.rb].each { autoload_normal.call(_1) }
%w[scheduling prog serializers].each { autoload_normal.call(_1, include_first: true) }

AUTOLOAD_CONSTANTS.freeze

if Config.production? || Config.e2e_test?
  AUTOLOAD_CONSTANTS.each { Object.const_get(_1) }
end

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

def clover_freeze
  return unless Config.production? || Config.e2e_test?
  require "refrigerator"

  # Take care of library dependencies that modify core classes.

  # For at least Puma, per
  # https://github.com/jeremyevans/roda-sequel-stack/blob/931e810a802b2ab14628111cfce596998316b556/config.ru#L41C6-L42C1
  require "yaml"

  # Also for at least puma, but not itemized by the roda-sequel-stack
  # project for some reason.
  require "nio4r"

  # this Ruby standard library method patches core classes.
  "".unicode_normalize(:nfc)

  # A standard library method that edits/creates a module variable as
  # a side effect.  We encountered it when using rubygems for its tar
  # file writing.
  Gem.source_date_epoch

  Refrigerator.freeze_core
end
