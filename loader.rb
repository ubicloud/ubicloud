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
require "warning"
require "rack/unreloader"

REPL = false unless defined? REPL
Warning.ignore(/To use (retry|multipart) middleware with Faraday v2\.0\+, install `faraday-(retry|multipart)` gem/)

force_autoload = Config.production? || ENV["FORCE_AUTOLOAD"] == "1"
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

  # Copied from sequel/model/inflections.rb's camelize, to convert
  # file paths into module and class names.
  camelize = ->(s) do
    s.gsub(/\/(.?)/) { |x| "::#{x[-1..].upcase}" }.gsub(/(^|_)(.)/) { |x| x[-1..].upcase }
  end

  Unreloader.autoload(absolute) do |f|
    full_name = camelize.call((include_first ? subdirectory + File::SEPARATOR : "") + rgx.match(f)[1])
    AUTOLOAD_CONSTANTS << full_name unless AUTOLOAD_CONSTANTS.frozen?
    full_name
  end
end

# Define empty modules instead of trying to have autoload_normal create them via metaprogramming
module Hosting; end

module Minio; end

module Prog; end

module Prog::Ai; end

module Prog::DnsZone; end

module Prog::Github; end

module Prog::Minio; end

module Prog::Postgres; end

module Prog::Storage; end

module Prog::Vm; end

module Prog::Vnet; end

module Scheduling; end

module Serializers; end

module Routes; end

module Routes::Common; end

autoload_normal.call("model", flat: true)
%w[lib clover.rb clover_web.rb clover_api.rb clover_runtime.rb routes/clover_base.rb routes/clover_error.rb].each { autoload_normal.call(_1) }
%w[scheduling prog serializers routes/common].each { autoload_normal.call(_1, include_first: true) }

if ENV["LOAD_FILES_SEPARATELY_CHECK"] == "1"
  files = %w[model lib scheduling prog serializers routes/common].flat_map { Dir["#{_1}/**/*.rb"] }
  files.concat(%w[clover.rb clover_web.rb clover_api.rb clover_runtime.rb routes/clover_base.rb routes/clover_error.rb])
  files.each do |file|
    pid = fork do
      require_relative file
      exit(0)
    rescue LoadError, StandardError => e
      puts "ERROR: problems loading #{file}: #{e.class}: #{e.message}"
    end
    Process.wait(pid)
  end
  exit(0)
end

AUTOLOAD_CONSTANTS.freeze

if force_autoload
  AUTOLOAD_CONSTANTS.each { Object.const_get(_1) }

  # All classes are already available, so speed up UBID.class_for_ubid using
  # hash of prefixes to class objects
  class UBID
    TYPE2CLASS = TYPE2CLASSNAME.transform_values { Object.const_get(_1) }.freeze
    private_constant :TYPE2CLASS

    singleton_class.remove_method(:class_for_ubid)
    def self.class_for_ubid(str)
      TYPE2CLASS[str[..1]]
    end
  end
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
  return unless Config.production?
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

  # Aws SDK started to autoload modules when used, so we need to load them
  # before freezing. https://github.com/aws/aws-sdk-ruby/pull/3105
  # rubocop:disable Lint/Void
  Aws::S3::Client
  Aws::S3::Presigner
  Aws::S3::Errors
  # rubocop:enable Lint/Void

  # A standard library method that edits/creates a module variable as
  # a side effect.  We encountered it when using rubygems for its tar
  # file writing.
  Gem.source_date_epoch

  Refrigerator.freeze_core
end
