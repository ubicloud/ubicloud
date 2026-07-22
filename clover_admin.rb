# frozen_string_literal: true

require_relative "model"

require "roda"
require "tilt"
require "tilt/erubi"
require "openssl"

class CloverAdmin < Roda
  include AuditLog

  TableLink = Data.define(:value, :link)

  def table_link(...)
    TableLink.new(...)
  end

  TableFormButton = Data.define(:text, :attributes)

  def table_form_button(text, **attributes)
    TableFormButton.new(text, attributes)
  end

  Unreloader.record_dependency("lib/audit_log.rb", __FILE__)

  MIN_AUDIT_LOG_END_DATE = Date.new(2025, 6)

  AUDIT_LOG_PARAM_MAP = Hash.new("object")
  AUDIT_LOG_PARAM_MAP["Project"] = "project"
  AUDIT_LOG_PARAM_MAP["Account"] = "subject"
  AUDIT_LOG_PARAM_MAP.freeze

  # :nocov:
  if Config.development?
    plugin :exception_page

    class RodaRequest
      def assets
        exception_page_assets
        super
      end
    end
  end

  default_fixed_locals = if Config.production? || Config.frozen_test?
    "()"
  # :nocov:
  else
    "(_no_kw: nil)"
  end

  plugin :render, views: "views/admin", escape: true, assume_fixed_locals: true, template_opts: {
    chain_appends: !defined?(SimpleCov),
    freeze: true,
    skip_compiled_encoding_detection: true,
    scope_class: self,
    default_fixed_locals:,
    extract_fixed_locals: true,
  }

  # :nocov:
  if Config.test? && defined?(SimpleCov)
    plugin :render_coverage, dir: "coverage/views/admin"
  end

  plugin :ip_from_header, Config.ip_from_header if Config.ip_from_header
  # :nocov:

  plugin :part
  plugin :public
  plugin :flash
  plugin :h

  plugin :content_security_policy do |csp|
    csp.default_src :none
    csp.style_src :self
    csp.img_src :self    # /favicon.ico
    csp.script_src :self # webauthn
    csp.form_action :self
    csp.base_uri :none
    csp.frame_ancestors :none
  end

  plugin :sessions,
    key: "_CloverAdmin.session",
    env_key: "clover.admin.session",
    cookie_options: {secure: !(Config.development? || Config.test?)},
    secret: OpenSSL::HMAC.digest("SHA512", Config.clover_session_secret, "admin-site")

  UBID_REGEXP = /\A[a-tv-z0-9]{26}\z/
  UUID_REGEXP = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/i

  plugin :typecast_params_sized_integers, sizes: [64], default_size: 64
  plugin :typecast_params do
    handle_type(:ubid) do
      it if UBID_REGEXP.match?(it)
    end

    handle_type(:uuid) do
      it if UUID_REGEXP.match?(it)
    end

    handle_type(:ubid_uuid) do
      UBID.to_uuid(it) if UBID_REGEXP.match?(it)
    end
  end

  plugin :symbol_matchers
  symbol_matcher(:ubid, /([a-tv-z0-9]{26})/, segment: true)
  symbol_matcher(:ubid_uuid, :ubid) { UBID.to_uuid(it) }

  plugin :not_found do
    raise "admin route not handled: #{request.path}" if Config.test? && !ENV["DONT_RAISE_ADMIN_ERRORS"]

    @page_title = "File Not Found"
    if (ubid = request.path.split("/").find { UBID_REGEXP.match?(it) })
      view(content: "<p>Try <a href=\"/archived-record-by-id?id=#{h ubid}\">searching archived records</a></p>")
    else
      view(content: "")
    end
  end

  plugin :route_csrf do |token|
    flash.now["error"] = "An invalid security token submitted with this request, please try again"
    @page_title = "Invalid Security Token"
    view(content: "")
  end

  plugin :error_handler do |e|
    # :nocov:
    next exception_page(e, assets: true) if Config.development?
    # :nocov:

    raise e if Config.test? && !ENV["DONT_RAISE_ADMIN_ERRORS"]

    @page_title = if e.is_a?(CloverError)
      "#{e.type}: #{e.message}"
    else
      Clog.emit("admin route exception", Util.exception_to_hash(e))
      "Internal Server Error"
    end
    view(content: "")
  end

  plugin :forme_route_csrf
  Forme.register_config(:clover_admin, base: :default, labeler: :explicit)
  Forme.default_config = :clover_admin

  def self.create_admin_account(login)
    if Config.production? && defined?(Pry)
      raise "cannot create admin account in production via pry as it would log the password"
    end

    password = SecureRandom.urlsafe_base64(16)
    rodauth.create_account(login:, password:)
    Clog.emit("Created admin account", {admin_account_created: login})
    password
  end

  def linkify_ubids(body)
    h(body).gsub(/\b[a-tv-z0-9]{26}\b/) do
      if (klass = UBID.class_for_ubid(it))
        "<a href=\"/model/#{klass}/#{it}\">#{it}</a>"
      else
        it
      end
    end
  end

  def format_bytes(bytes)
    if bytes < 1024
      "#{bytes.round}B"
    elsif bytes < 1024**2
      "#{(bytes / 1024.0).round(1)}KiB"
    elsif bytes < 1024**3
      "#{(bytes / 1024.0**2).round(1)}MiB"
    else
      "#{(bytes / 1024.0**3).round(1)}GiB"
    end
  end

  def format_seconds(s)
    m, s = s.divmod(60)
    h, m = m.divmod(60)
    "%02d:%02d:%02d" % [h, m, s]
  end

  def _classes
    classes = []
    Sequel::Model.subclasses.each do |c|
      classes << c if yield c
      c.subclasses.each do |sc|
        classes << sc if yield sc
      end
    end
    classes.sort_by!(&:name)
  end

  def available_classes
    _classes { it < ResourceMethods::InstanceMethods }
  end

  def customer_vm_dataset
    vm = Sequel[:vm]
    customer_project_id = Sequel.function(:coalesce, Sequel[:pg][:project_id], Sequel[:kc][:project_id], Sequel[:gi][:project_id], vm[:project_id])
    DB[:vm]
      .left_join(Sequel[:postgres_server].as(:ps), vm_id: vm[:id])
      .left_join(Sequel[:postgres_resource].as(:pg), id: Sequel[:ps][:resource_id])
      .left_join(Sequel[:kubernetes_node].as(:kn), vm_id: vm[:id])
      .left_join(Sequel[:kubernetes_cluster].as(:kc), id: Sequel[:kn][:kubernetes_cluster_id])
      .left_join(Sequel[:github_runner].as(:gr), vm_id: vm[:id])
      .left_join(Sequel[:github_installation].as(:gi), id: Sequel[:gr][:installation_id])
      .select(
        vm[:id].as(:vm_id),
        vm[:name].as(:vm_name),
        vm[:vcpus],
        vm[:created_at],
        vm[:vm_host_id],
        customer_project_id.as(:project_id),
        Sequel[:pg][:id].as(:pg_resource_id),
        Sequel[:pg][:name].as(:pg_resource_name),
        Sequel[:kc][:id].as(:kubernetes_cluster_id),
        Sequel[:kc][:name].as(:kubernetes_cluster_name),
        Sequel[:gr][:id].as(:github_runner_id),
        Sequel[:gi][:name].as(:github_installation_name),
      )
      .from_self(alias: :cvm)
  end

  # Classify a customer_vm_dataset row into a [type, resource_link] pair.
  def customer_resource_type(row)
    if row[:pg_resource_id]
      ["PostgreSQL", table_link(row[:pg_resource_name], "/model/PostgresResource/#{UBID.to_ubid(row[:pg_resource_id])}")]
    elsif row[:kubernetes_cluster_id]
      ["Kubernetes", table_link(row[:kubernetes_cluster_name], "/model/KubernetesCluster/#{UBID.to_ubid(row[:kubernetes_cluster_id])}")]
    elsif row[:github_runner_id]
      ["GitHub Runner", table_link(row[:github_installation_name], "/model/GithubRunner/#{UBID.to_ubid(row[:github_runner_id])}")]
    else
      ["VM", nil]
    end
  end

  # Email of the earliest-created account per project (one row per project via
  # DISTINCT ON), used to make customers identifiable since project names are
  # frequently just "Default".
  def customer_email_dataset
    DB[:access_tag]
      .join(:accounts, id: Sequel[:access_tag][:hyper_tag_id])
      .distinct(Sequel[:access_tag][:project_id])
      .order(Sequel[:access_tag][:project_id], Sequel[:accounts][:created_at], Sequel[:accounts][:email])
      .select(
        Sequel[:access_tag][:project_id],
        Sequel[:accounts][:email],
      )
  end

  # Human-readable project label combining the project name with its account
  # email, when present.
  def project_label(name, email)
    email ? "#{name} (#{email})" : name
  end

  ROLLOUT_SEMAPHORE_OPTIONS = Prog::RolloutSemaphore::ALLOWED_SEMAPHORES_PER_RESOURCE_TYPE.flat_map do |klass, semaphores|
    semaphores.map { "#{klass.name} - #{it}" }
  end.freeze

  skip_webauthn_requirement = Config.development? && Config.clover_admin_development_no_webauthn?

  plugin :rodauth, route_csrf: true do
    enable :argon2, :login, :logout, :webauthn, :change_password, :close_account, :internal_request,
      :audit_logging

    internal_request_configuration do
      enable :create_account
      require_email_address_logins? false
      password_meets_requirements? do |password|
        # uses a randomly generated password
        true
      end
    end

    uses_instance_variables(:@_webauthn_credential_id)

    accounts_table :admin_account
    password_hash_table :admin_password_hash
    webauthn_keys_table :admin_webauthn_key
    webauthn_user_ids_table :admin_webauthn_user_id
    login_column :login
    audit_logging_table :admin_account_authentication_audit_log

    # :nocov:
    unless skip_webauthn_requirement
      # :nocov:
      login_redirect do
        uses_two_factor_authentication? ? "/webauthn-auth" : "/webauthn-setup"
      end

      remove_webauthn_key do |webauthn_id|
        @_webauthn_credential_id = webauthn_id
        super(webauthn_id)
      end

      add_webauthn_credential do |webauthn_credential|
        @_webauthn_credential_id = webauthn_credential.id
        super(webauthn_credential)
      end
    end

    audit_log_metadata do |action|
      hash = {}

      if (ip = request.ip || session[:ip])
        hash["ip"] = ip
      end

      case action
      when :two_factor_authentication
        webauthn_credential_id = authenticated_webauthn_id
      when :webauthn_setup, :webauthn_remove
        webauthn_credential_id = @_webauthn_credential_id
      when :close_account
        if (closer = session[:closer])
          hash["closer"] = closer
        end
      end

      if webauthn_credential_id
        hash["token"] = webauthn_credential_id[0...8]
      end

      hash
    end

    check_csrf? false
    require_bcrypt? false
    skip_status_checks? true
    title_instance_variable :@page_title
    argon2_secret OpenSSL::HMAC.digest("SHA256", Config.clover_session_secret, "admin-argon2-secret")
    hmac_secret OpenSSL::HMAC.digest("SHA512", Config.clover_session_secret, "admin-rodauth-hmac-secret")
    function_name(&{
      rodauth_get_salt: :rodauth_admin_get_salt,
      rodauth_valid_password_hash: :rodauth_admin_valid_password_hash,
    }.to_proc)

    close_account_redirect "/login"
    before_close_account do
      login = account_from_session[:login]
      closer = session[:closer] || login
      Clog.emit("Admin account closed", {admin_account_closed: {account_closed: login, closer:}})
    end

    password_minimum_length 16
    password_maximum_bytes 72
    password_meets_requirements? do |password|
      super(password) && password.match?(/[a-z]/) && password.match?(/[A-Z]/) && password.match?(/[0-9]/)
    end
  end

  ObjectAction = Data.define(:label, :flash, :params, :type, :action) do
    def self.define(label, flash: nil, params: {}, type: :normal, &action)
      new(label, flash, params.dup.freeze, type, action)
    end

    def call(...)
      action.call(...)
    end
  end

  def self.object_action(...)
    ObjectAction.define(...)
  end

  github_page_action = object_action("GitHub Page", type: :direct) do |obj|
    "http://github.com/#{obj.name}"
  end

  OBJECT_ACTIONS = {
    "Account" => {
      "suspend" => object_action("Suspend", flash: "Account suspended", &:suspend),
      "unsuspend" => object_action("Unsuspend", flash: "Account unsuspended", &:unsuspend),
    },
    "BootImage" => {
      "remove_boot_image" => object_action("Remove Boot Image", flash: "Boot image removal scheduled", &:remove_boot_image),
      "activate_boot_image" => object_action("Activate Boot Image", flash: "Boot image activated") do |obj|
        obj.update(activated_at: Time.now)
      end,
      "disable_boot_image" => object_action("Disable Boot Image", flash: "Boot image disabled") do |obj|
        obj.update(activated_at: nil)
      end,
    },
    "DnsZone" => {
      "add_record" => object_action("Add DNS Record", flash: "Added DNS Record",
        params: {
          name: {typecast: :nonempty_str!, label: "name (without zone)"},
          type: {typecast: :nonempty_str!},
          data: {typecast: :nonempty_str!},
          ttl: {typecast: :pos_int!, type: :number, attr: {min: 60, max: 3600}, value: 600},
        }) do |obj, record_name, type, data, ttl|
          record_name += ".#{obj.name}."
          obj.insert_record(record_name:, type:, ttl:, data:)
        end,
    },
    "DnsRecord" => {
      "delete" => object_action("Delete DNS Record", flash: "Deleted DNS Record") do |obj|
        dns_zone = DnsZone.with_pk!(obj.dns_zone_id)
        dns_zone.delete_record(record_name: obj.name, type: obj.type, data: obj.data)
      end,
    },
    "GithubInstallation" => {
      "github_page" => github_page_action,
    },
    "GithubRepository" => {
      "github_page" => github_page_action,
      "show_job_log" => object_action("Show Job Log", params: {job_ids: {typecast: :nonempty_str!, label: "Job IDs (comma-separated)"}}, type: :content) do |obj, job_ids|
        client = obj.installation.client
        items = job_ids.split(",").filter_map do |job_id|
          job_id.strip!
          next if job_id.empty?

          unless (id = Integer(job_id, exception: false)) && id.between?(1, 2**63 - 1)
            next "<li>Job #{Erubi.h(job_id)}: invalid job ID</li>"
          end

          begin
            url = client.workflow_run_job_logs(obj.name, id)
            "<li><a href=\"#{Erubi.h(url)}\" target=\"_blank\">Job #{id}: Show Log</a></li>"
          rescue Octokit::Error => e
            "<li>Job #{id}: #{e.class}: #{Erubi.h(e.message)}</li>"
          end
        end
        "<ol>#{items.join}</ol>"
      end,
    },
    "GithubRunner" => {
      "provision" => object_action("Provision Spare Runner", flash: "Spare runner provisioned", type: :form, &:provision_spare_runner),
    },
    "Invoice" => {
      "download_pdf" => object_action("Download PDF", type: :direct) do |obj|
        obj.generate_download_link
      end,
    },
    "OidcProvider" => {
      "add_allowed_domain" => object_action("Add Allowed Domain", flash: "Added allowed domain", params: {domain: {typecast: :nonempty_str!}}) do |obj, domain|
        obj.add_allowed_domain(domain)
      end,
      "remove_allowed_domain" => object_action("Remove Allowed Domain", flash: "Removed allowed domain",
        params: ->(obj) {
          {domain: {typecast: :nonempty_str!, type: "select", add_blank: true, required: true, options: obj.allowed_domains}}
        }) do |obj, domain|
          obj.remove_allowed_domain(domain)
        end,
    },
    "Page" => {
      "resolve" => object_action("Resolve", flash: "Resolve scheduled for Page", &:incr_resolve),
      "retrigger" => object_action("Retrigger", flash: "Retrigger scheduled for Page", &:incr_retrigger),
    },
    "PostgresResource" => {
      "restart" => object_action("Restart", flash: "Restart scheduled for PostgresResource") do |obj|
        obj.server_incr("restart")
      end,
    },
    "PostgresServer" => {
      "recycle" => object_action("Recycle", flash: "Recycle scheduled for PostgresServer", &:incr_recycle),
    },
    "Project" => {
      "add_credit" => object_action("Add credit", flash: "Added credit", params: {credit: {typecast: :float!, type: "number", attr: {min: -10**6, max: 10**6}}}) do |obj, credit|
        obj.this.update(credit: Sequel[:credit] + credit)
      end,
      "set_feature_flag" => object_action("Set Feature Flag", flash: "Set feature flag", params: {
        name: {
          typecast: :str!,
          type: "select",
          add_blank: true,
          options: Project.instance_methods.grep(/\Aset_ff_/).map! { it[7...] }.sort!,
        },
        value: {
          typecast: :nonempty_str,
          placeholder: "JSON",
          required: nil,
        },
      }) do |obj, name, value|
        begin
          value = JSON.parse(value) if value
        rescue JSON::ParserError
          fail CloverError.new(400, "InvalidRequest", "invalid JSON for feature flag value")
        end
        obj.send("set_ff_#{name}", value)
      end,
      "set_quota" => object_action("Set Quota", flash: "Set quota", params: {
        resource_type: {
          typecast: :str!,
          type: "select",
          add_blank: true,
          options: ProjectQuota.default_quotas.keys,
        },
        value: {
          typecast: :int,
          type: "number",
          placeholder: "blank to reset to default",
          required: nil,
        },
      }) do |obj, resource_type, value|
        quota_id = ProjectQuota.default_quotas[resource_type]["id"]
        if (existing_quota = obj.quotas_dataset.first(quota_id:))
          if value
            existing_quota.update(value:)
          else
            existing_quota.destroy
          end
        elsif value
          obj.add_quota(quota_id:, value:)
        end
      end,
    },
    "Strand" => {
      "subject" => object_action("Subject", type: :direct) do |obj|
        "/model/#{obj.subject.class}/#{obj.subject.ubid}"
      end,
      "schedule" => object_action("Schedule Strand to Run Immediately", flash: "Scheduled strand to run immediately", type: :form) do |obj|
        obj.this.update(schedule: Sequel::CURRENT_TIMESTAMP)
      end,
      "extend" => object_action("Extend Schedule", flash: "Extended schedule", params: {minutes: {typecast: :pos_int!, type: "number", attr: {min: 1, max: 1440}}}) do |obj, minutes|
        obj.this.update(schedule: Sequel.date_add(:schedule, minutes:))
      end,
      "incr_semaphore" => object_action("Increment Semaphore", flash: "Incremented semaphore", params: ->(obj) {
        subject_class = obj.subject.class
        options = subject_class.respond_to?(:semaphore_names) ? subject_class.semaphore_names.map(&:name).sort! : [].freeze
        {
          name: {typecast: :nonempty_str!, type: "select", add_blank: true, required: true, options:},
          name_confirmation: {typecast: :nonempty_str!, type: "select", add_blank: true, required: true, options:},
        }
      }) do |obj, name, name_confirmation|
        fail CloverError.new(400, "InvalidRequest", "Semaphore name confirmation does not match") unless name == name_confirmation
        Semaphore.incr(obj.id, name)
      end,
      "decr_semaphore" => object_action("Decrement Semaphore", flash: "Decremented semaphore", params: ->(obj) {
        options = obj.semaphores_dataset.distinct.select_order_map(:name)
        {
          name: {typecast: :nonempty_str!, type: "select", add_blank: true, required: true, options:},
          name_confirmation: {typecast: :nonempty_str!, type: "select", add_blank: true, required: true, options:},
        }
      }) do |obj, name, name_confirmation|
        fail CloverError.new(400, "InvalidRequest", "Semaphore name confirmation does not match") unless name == name_confirmation
        Semaphore.where(strand_id: obj.id, name:).destroy
      end,
    },
    "Vm" => {
      "restart" => object_action("Restart", flash: "Restart scheduled for Vm", &:incr_restart),
      "stop" => object_action("Stop", flash: "Stop scheduled for Vm") do |obj|
        DB.transaction do
          obj.incr_admin_stop
          obj.incr_stop
        end
      end,
    },
    "VmHost" => {
      "accept" => object_action("Move to Accepting", flash: "Host allocation state changed to accepting") do |obj|
        obj.update(allocation_state: "accepting")
      end,
      "drain" => object_action("Move to Draining", flash: "Host allocation state changed to draining") do |obj|
        obj.update(allocation_state: "draining")
      end,
      "reset" => object_action("Hardware Reset", flash: "Hardware reset scheduled for VmHost", &:incr_hardware_reset),
      "reboot" => object_action("Reboot", flash: "Reboot scheduled for VmHost", &:incr_reboot),
      "move_location" => object_action("Move to Location", flash: "Location updated and missing boot image downloads started", params: {
        location: {
          typecast: :ubid_uuid!,
          type: "select",
          add_blank: true,
          required: true,
          options: Location
            .where(project_id: nil, provider: %w[hetzner leaseweb].freeze)
            .or(id: Location::GITHUB_RUNNERS_ID)
            .select_order_map([:display_name, :id])
            .each { it[1] = UBID.to_ubid(it[1]) },
        },
      }) do |obj, target_location_id|
        obj.move_to_location(target_location_id)
      end,
      "force_create_vm" => object_action("Force Create VM", flash: "VM creation scheduled", params: ->(obj) {
        {
          project_id: {typecast: :ubid_uuid!, required: true, placeholder: "Project UBID"},
          public_key: {typecast: :nonempty_str!, required: true},
          name: {typecast: :nonempty_str, required: nil, placeholder: "auto-generated if blank"},
          size: {
            typecast: :nonempty_str!,
            type: "select",
            required: true,
            options: Option::VmSizes.select { it.arch == obj.arch && (it.family == obj.family || (it.family == "burstable" && obj.accepts_slices)) }.map(&:name),
          },
          boot_image: {
            typecast: :nonempty_str!,
            type: "select",
            required: true,
            options: obj.boot_images_dataset.exclude(activated_at: nil).distinct.select_order_map(:name),
          },
        }
      }) do |obj, project_id, public_key, name, size, boot_image|
        Prog::Vm::Nexus.assemble(public_key, project_id, name:, size:, boot_image:,
          location_id: obj.location_id, arch: obj.arch, force_host_id: obj.id, enable_ip4: true)
      end,
    },
  }.freeze
  OBJECT_ACTIONS.each_value(&:freeze)

  SEARCH_QUERIES = {
    "Account" => [:email, :name],
    "BillingInfo" => [:stripe_id],
    "GithubInstallation" => [:name],
    "GithubRepository" => [:name],
    "Invoice" => [:invoice_number],
    "KubernetesCluster" => [:name],
    "PostgresResource" => [:name],
    "Vm" => [:name],
  }.freeze
  SEARCH_QUERIES.each_value(&:freeze)
  SEARCH_PREFIXES = SEARCH_QUERIES.map { "#{Object.const_get(it[0]).ubid_type} (#{it[0]})" }.join(", ").freeze

  OBJECTS_WITH_UI = {
    "Vm" => lambda { |vm| "project/#{vm.project.ubid}/location/#{vm.location.display_name}/vm/#{vm.ubid}/overview" },
    "PostgresResource" => lambda { |pg| "project/#{pg.project.ubid}/location/#{pg.location.display_name}/postgres/#{pg.name}/overview" },
  }.freeze

  OBJECTS_WITH_EXTRAS = Dir["views/admin/extras/*.erb"]
    .map { File.basename(it, ".erb") }
    .each_with_object({}) { |name, h| h[name] = true }
    .freeze

  OBJECT_ASSOC_TABLE_PARAMS = {
    ["GithubInstallation", :runners] => "installation",
    ["GithubInstallation", :repositories] => "installation",
    ["GithubRepository", :runners] => "repository",
    ["Project", :vms] => "project",
    ["Project", :postgres_resources] => "project",
    ["Project", :invoices] => "project",
    ["PostgresResource", :servers] => "resource",
    ["Strand", :children] => "parent",
    ["VmHost", :boot_images] => "vm_host",
    ["VmHost", :vms] => "vm_host",
  }.freeze

  ROLLOUT_PROGS = %w[
    RolloutBootImage
    RolloutRhizome
    RolloutSemaphore
  ].freeze

  LOCAL_E2E_PROGS = Prog::Test::LocalE2eLoop::ALLOWED_PROGS
  LOCAL_E2E_PROVIDERS = %w[
    aws
    metal
  ].freeze

  plugin :autoforme do
    # :nocov:
    register_by_name if Config.development?
    # :nocov:

    framework = self

    pagination_strategy :filter
    order [:id]
    supported_actions [:browse, :search]
    form_options(wrapper: :div)

    link = lambda do |obj, label: "admin_label"|
      return "" unless obj

      "<a href=\"/model/#{obj.class}/#{obj.ubid}\">#{Erubi.h(obj.send(label))}</a>"
    end

    show_html do |obj, column|
      case column
      when :name, :ubid, :invoice_number
        link.call(obj, label: column)
      when :project, :location, :vm_host, :billing_info, :resource, :parent, :installation
        link.call(obj.send(column))
      when :vm
        link.call(obj.send(column), label: :ubid)
      when :subtotal, :cost
        "$%0.02f" % (obj.send(column) || 0)
      end
    end

    column_grep = lambda do |ds, column, value|
      ds.where(Sequel.cast(column, :text).ilike("%#{ds.escape_like(value)}%"))
    end

    ubid_uuid_grep = lambda do |ds, column, value|
      uuid = if UBID_REGEXP.match?(value)
        UBID.to_uuid(value)
      elsif UUID_REGEXP.match?(value)
        value
      end
      ds.where(column => uuid)
    end

    column_search_filter do |model, ds, column, value|
      case column
      when :created_at
        column_grep.call(ds, :created_at, value)
      when :project
        ubid_uuid_grep.call(ds, :project_id, value)
      when :vm_host
        ubid_uuid_grep.call(ds, :vm_host_id, value)
      end
    end

    ubid_input = lambda do |name|
      {type: "text", placeholder: "#{name} UBID/UUID", maxlength: 36, minlength: 26}
    end

    model Firewall do
      eager [:project, :location]
      columns [:name, :project, :location, :description]
    end

    model Account do
      order Sequel.desc(Sequel[:accounts][:created_at])
      eager_graph [:identities]
      columns [:name, :email, :status_id, :provider_names, :created_at, :suspended_at]
      column_options email: {type: "text"},
        status_id: {type: "select", options: {Unverified: 1, Verified: 2, Closed: 3}, add_blank: true},
        provider_names: {label: "Providers", type: "select", options: ["google", "github"], add_blank: true},
        created_at: {type: "text"},
        suspended_at: {label: "Suspended", type: "boolean", value: nil}

      column_search_filter do |ds, column, value|
        case column
        when :provider_names
          ds.where(provider: value)
        when :created_at
          column_grep.call(ds, Sequel[:accounts][:created_at], value)
        when :suspended_at
          ds.send((value == "t") ? :exclude : :where, suspended_at: nil)
        end
      end
    end

    model BillingInfo do
      order Sequel.desc(Sequel[:billing_info][:created_at])
      eager_graph [:project]
      columns do |type_symbol, request|
        cs = [:stripe_id, :project, :valid_vat, :created_at]
        cs.prepend(:ubid) unless type_symbol == :search_form
        cs
      end
      column_options project: ubid_input.call("Project"),
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :project
          ubid_uuid_grep.call(ds, Sequel[:project][:id], value)
        when :created_at
          column_grep.call(ds, Sequel[:billing_info][:created_at], value)
        end
      end
    end

    model GithubInstallation do
      order Sequel.desc(:created_at)
      columns [:name, :installation_id, :type, :cache_enabled, :premium_runner_enabled?, :created_at, :allocator_preferences]

      column_options type: {type: "select", options: ["Organization", "User"], add_blank: true},
        premium_runner_enabled?: {label: "Premium enabled", type: "boolean", value: nil},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :premium_runner_enabled?
          family_filter = Sequel.pg_jsonb(:allocator_preferences).get("family_filter")
          cond = family_filter.contains(["premium"])
          if value == "t"
            ds.where(cond)
          else
            ds.where(~cond | {family_filter => nil})
          end
        when :allocator_preferences, :created_at
          column_grep.call(ds, column, value)
        end
      end
    end

    model GithubRepository do
      order Sequel.desc(:created_at)
      eager [:installation]
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:installation, :name, :created_at]
        else
          [:name, :created_at, :last_job_at]
        end
      end
      column_options installation: ubid_input.call("Installation"),
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :installation
          ubid_uuid_grep.call(ds, :installation_id, value)
        else
          framework
        end
      end
    end

    model GithubRunner do
      order Sequel.desc(:created_at)
      eager_graph [:strand]
      eager [:installation]
      columns do |type_symbol, request|
        cs = [:repository_name, :label, :strand_label, :created_at]
        cs.prepend(:repository, :installation) if type_symbol == :search_form
        cs.prepend(:ubid) unless type_symbol == :search_form
        cs
      end

      column_options strand_label: {type: "text"},
        created_at: {type: "text"},
        installation: ubid_input.call("Installation"),
        repository: ubid_input.call("Repository")

      column_search_filter do |ds, column, value|
        case column
        when :strand_label
          column_grep.call(ds, Sequel[:strand][:label], value)
        when :installation, :repository
          ubid_uuid_grep.call(ds, :"#{column}_id", value)
        else
          framework
        end
      end
    end

    model Invoice do
      order Sequel.desc(:invoice_number)
      eager_graph [:project]
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:invoice_number, :project, :status]
        else
          [:invoice_number, :project, :status, :subtotal, :cost]
        end
      end
      column_options status: {type: "select", options: %w[unpaid paid fraud waiting_transfer below_minimum_threshold].freeze, add_blank: true},
        project: ubid_input.call("Project")

      column_search_filter do |ds, column, value|
        case column
        when :project
          ubid_uuid_grep.call(ds, Sequel[:project][:id], value)
        end
      end
    end

    model PaymentMethod do
      order Sequel.desc(:created_at)
      eager [:billing_info]
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:stripe_id, :fraud, :created_at]
        else
          [:ubid, :stripe_id, :billing_info, :fraud, :created_at]
        end
      end
      column_options fraud: {type: "boolean", value: nil},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :fraud
          ds.where(fraud: value == "t")
        else
          framework
        end
      end
    end

    model PostgresResource do
      order Sequel.desc(:created_at)
      eager do |type, _request|
        [:location, :parent, :project] unless type == :association
      end
      columns [:name, :project, :location, :flavor, :target_vm_size, :target_storage_size_gib, :ha_type, :target_version, :parent, :created_at]
      column_options flavor: {type: "select", options: %w[standard paradedb lantern].freeze, add_blank: true},
        ha_type: {type: "select", options: %w[none async sync].freeze, add_blank: true},
        target_version: {type: "select", options: Option::POSTGRES_VERSION_OPTIONS[PostgresResource::Flavor::STANDARD], add_blank: true},
        target_storage_size_gib: {type: "number"},
        project: ubid_input.call("Project"),
        parent: ubid_input.call("Parent"),
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :parent
          ubid_uuid_grep.call(ds, :parent_id, value)
        else
          framework
        end
      end
    end

    model PostgresServer do
      order Sequel.desc(:created_at)
      eager [:resource, :vm]
      columns do |type_symbol, request|
        cs = [:resource, :timeline_access, :synchronization_status, :version, :is_representative, :created_at]
        unless type_symbol == :search_form
          cs.prepend(:vm)
          cs.prepend(:ubid)
        end
        cs
      end
      column_options resource: ubid_input.call("Resource"),
        timeline_access: {type: "select", options: %w[push fetch].freeze, add_blank: true},
        synchronization_status: {type: "select", options: %w[ready catching_up].freeze, add_blank: true},
        version: {type: "select", options: Option::POSTGRES_VERSION_OPTIONS[PostgresResource::Flavor::STANDARD], add_blank: true},
        created_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :resource
          ubid_uuid_grep.call(ds, :resource_id, value)
        else
          framework
        end
      end
    end

    model Project do
      order Sequel.desc(:created_at)
      columns [:name, :reputation, :billing_info_id, :credit, :created_at]
      column_options reputation: {type: "select", options: %w[new verified limited].freeze, add_blank: true},
        created_at: {type: "text"}
    end

    model Strand do
      order Sequel.desc(:try)
      columns do |type_symbol, request|
        if type_symbol == :search_form
          [:prog, :label, :try, :parent]
        else
          [:ubid, :prog, :label, :schedule, :try]
        end
      end
      column_options try: {type: "number", value: nil},
        parent: ubid_input.call("Parent")

      column_search_filter do |ds, column, value|
        if column == :parent
          ubid_uuid_grep.call(ds, :parent_id, value)
        end
      end
    end

    model Vm do
      order Sequel.desc(:created_at)
      eager do |type, _request|
        [:location, :vm_host, :project, :strand, :semaphores] unless type == :association
      end
      columns [:name, :display_state, :project, :vm_host, :location, :arch, :boot_image, :family, :vcpus, :created_at]
      column_options display_state: {type: "select", options: ["running", "creating", "starting", "rebooting", "deleting"], add_blank: true},
        arch: {type: "select", options: ["x64", "arm64"], add_blank: true},
        family: {type: "select", options: Option::VmFamilies.map(&:name), add_blank: true},
        vcpus: {type: "number"},
        created_at: {type: "text"},
        project: ubid_input.call("Project"),
        vm_host: ubid_input.call("VmHost")
    end

    model BootImage do
      order Sequel.desc(:created_at)
      eager [:vm_host]
      columns [:name, :version, :vm_host, :size_gib, :activated_at, :created_at]
      column_options vm_host: ubid_input.call("VmHost"),
        created_at: {type: "text"},
        activated_at: {type: "text"}

      column_search_filter do |ds, column, value|
        case column
        when :activated_at
          column_grep.call(ds, :activated_at, value)
        else
          framework
        end
      end
    end

    model VmHost do
      order Sequel[:vm_host][:id]
      eager [:location]
      eager_graph [:sshable]
      columns do |type_symbol, request|
        cs = [:sshable_host, :allocation_state, :arch, :location, :data_center, :family, :total_cores, :total_hugepages_1g]
        cs.prepend(:ubid) unless type_symbol == :search_form
        cs
      end
      column_options sshable_host: {label: "Sshable", type: :text, value: ""},
        allocation_state: {type: "select", options: ["accepting", "draining", "unprepared"], add_blank: true},
        arch: {type: "select", options: ["x64", "arm64"], add_blank: true},
        family: {type: "select", options: Option::VmFamilies.map(&:name), add_blank: true},
        total_cores: {type: "number"},
        total_hugepages_1g: {type: "number"}

      column_search_filter do |ds, column, value|
        if column == :sshable_host
          column_grep.call(ds, Sequel[:sshable][:host], value)
        end
      end
    end
  end

  def audit_log_paginate
    if @pagination_key
      @next_page_params["pagination_key"] = @pagination_key
      "Next Page"
    elsif @next_end_date
      @next_page_params["end"] = @next_end_date
      "Older Results"
    end
  end

  def strand_semaphore_action(strand_ds, allowed_progs, additional_semaphores: {}.freeze)
    r = request
    matched_path = r.matched_path
    semaphores = allowed_semaphores = %w[pause unpause destroy].freeze
    semaphores += additional_semaphores.values.flatten unless additional_semaphores.empty?
    r.post :ubid_uuid, semaphores do |strand_id, action|
      unless (strand = strand_ds.with_pk(strand_id))
        flash["error"] = "Strand not found, it was probably already deleted"
        r.redirect matched_path
      end

      prog = strand.prog.split("::").last
      if (!additional_semaphores[prog]&.include?(action) && !allowed_semaphores.include?(action)) ||
          !allowed_progs.include?(prog)
        raise "invalid strand"
      end

      case action
      when "unpause"
        Semaphore.where(strand_id: strand.id, name: "pause").destroy
        strand.this.update(schedule: Sequel::CURRENT_TIMESTAMP)
      else
        Semaphore.incr(strand.id, action)
      end

      flash_action = case action
      when "destroy"
        "destroyed"
      when "pause", "unpause"
        action + "d"
      else
        "updated"
      end
      flash["notice"] = "Strand #{strand.ubid} #{flash_action}"
      r.redirect matched_path
    end
  end

  route do |r|
    r.public
    check_csrf!
    r.rodauth
    rodauth.require_authentication
    rodauth.require_account

    # :nocov:
    rodauth.require_two_factor_setup unless skip_webauthn_requirement
    r.exception_page_assets if Config.development?
    # :nocov:

    r.on "model", /([A-Z][a-zA-Z]+)/ do |model_name|
      begin
        @klass = Object.const_get(model_name)
      rescue NameError
        next
      end

      next unless @klass.is_a?(Class) && @klass < ResourceMethods::InstanceMethods

      r.get true do
        limit = 101
        ds = @klass.limit(limit).order(:id)

        if (after = typecast_params.ubid_uuid("after"))
          ds = ds.where { id > after }
        end

        @objects = ds.all

        if @objects.length == limit
          @objects.pop
          @after = @objects.last.ubid
        end

        view("objects")
      end

      r.on :ubid do |ubid|
        next unless (@obj = @klass[ubid])

        r.get true do
          view("object")
        end

        if (actions = OBJECT_ACTIONS[@obj.class.name])
          r.is actions.keys do |key|
            action = actions[key]
            action_type = action.type
            @label = action.label
            @params = action.params.is_a?(Proc) ? action.params.call(@obj) : action.params

            r.get(action_type != :form) do
              if action_type == :direct
                url = action.call(@obj) || fail(CloverError.new(400, "InvalidRequest", "Action link is not available"))
                r.redirect url
              end
              view("object_action")
            end

            r.post(action_type != :direct) do
              begin
                params = @params.map { |k, v| typecast_params.send(v[:typecast], k.to_s) }
              rescue Roda::RodaPlugins::TypecastParams::Error => e
                flash.now["error"] = "Invalid parameter submitted: #{e.param_name}"
                next view("object_action")
              end

              result = action.call(@obj, *params)
              if action_type == :content
                view(content: result)
              else
                flash["notice"] = action.flash
                r.redirect("/model/#{@obj.class}/#{ubid}")
              end
            end
          end
        end
      end
    end

    r.on "autoforme" do
      autoforme
    end

    r.get "archived-record-by-id" do
      @id = if (uuid = typecast_params.uuid("id"))
        UBID.from_uuidish(uuid)
      elsif (ubid = typecast_params.ubid("id"))
        begin
          UBID.parse(ubid)
        rescue UBIDParseError
          fail CloverError.new(400, "InvalidRequest", "Invalid UBID provided")
        end
      elsif typecast_params.nonempty_str("id")
        fail CloverError.new(400, "InvalidRequest", "Invalid UBID or UUID provided")
      end
      @model_name = typecast_params.nonempty_str("model_name") || UBID.class_for_ubid(@id.to_s)&.name
      @days = (typecast_params.pos_int("days") || 5).clamp(1, 15)
      @classes = available_classes
      @record = if @id
        fail CloverError.new(400, "InvalidRequest", "Could not determine model name from ID") unless @model_name
        ArchivedRecord.find_by_id(@id.to_uuid, model_name: @model_name, days: @days)
      end

      view("archived_record_by_id")
    end

    r.get "vm-by-ipv4" do
      @days = (typecast_params.pos_int("days") || 5).clamp(1, 15)
      if (@ips_param = typecast_params.nonempty_str("ips"))
        ips = @ips_param.split(",").filter_map {
          begin
            NetAddr.parse_net(it.strip).to_s
          rescue
            nil
          end
        }

        active_vms = Vm.from_ips(ips).map {
          {
            ip: it.assigned_vm_address.ip.to_s,
            created_at: it.created_at,
            archived_at: nil,
            vm_id: it.ubid,
            vm_name: it.name,
            boot_image: it.boot_image,
            project_id: it.project.ubid,
          }
        }
        archived_vms = ArchivedRecord.vms_by_ips(ips, days: @days).map {
          {
            ip: it[:ip],
            created_at: it[:created_at],
            archived_at: it[:archived_at],
            vm_id: UBID.to_ubid(it[:vm_id]),
            vm_name: it[:vm_name],
            boot_image: it[:boot_image],
            project_id: UBID.to_ubid(it[:project_id]),
          }
        }
        @vms = (active_vms + archived_vms).sort_by { [it[:ip], -it[:created_at].to_i] }
      end

      view("vm_by_ipv4")
    end

    r.get "audit-log" do
      ds = DB[:audit_log]
      next_page_params = {}

      if (project_id = typecast_params.ubid_uuid("project"))
        ds = ds.where(project_id:)
        next_page_params["project"] = UBID.to_ubid(project_id)
      end

      audit_log_search(ds, resolve: nil, accounts_dataset: Account.dataset, month_limit: 6, min_end_date: MIN_AUDIT_LOG_END_DATE, next_page_params:)
      view("audit_log")
    end

    r.get "authentication-audit-log", ["admin", true].freeze do |admin|
      if admin
        @page_title = "Admin Authentication Audit Log"
        @account_name_map = DB[:admin_account].select_hash(:id, :login)
        table = :admin_account_authentication_audit_log
        accounts_dataset = DB[:admin_account]
        args = {account_columns: [:login].freeze}
      else
        @page_title = "Authentication Audit Log"
        table = :account_authentication_audit_log
        accounts_dataset = Account.dataset
      end

      authentication_audit_log_search(
        DB[table],
        accounts_dataset:,
        month_limit: 6,
        min_end_date: MIN_AUDIT_LOG_END_DATE,
        **args,
      )
      view("authentication_audit_log")
    end

    r.post "theme", %w[light dark system].freeze do |theme|
      if theme == "system"
        session.delete("theme")
      else
        session["theme"] = theme
      end
      r.redirect env["HTTP_REFERER"] || "/"
    end

    r.on "rollouts" do
      strand_ds = Strand.where(prog: ROLLOUT_PROGS)

      r.get true do
        @strands = strand_ds.order(:prog, :id).eager(:semaphores).all
        view("rollouts")
      end

      r.post "start", ROLLOUT_PROGS do |prog|
        st = if prog == "RolloutSemaphore"
          class_semaphore, increment = typecast_params.nonempty_str!(%w[class_semaphore increment].freeze)
          gap = typecast_params.pos_int!("gap")
          wait = typecast_params.nonempty_str("wait_label")
          location_id = typecast_params.ubid_uuid("location_id")

          unless ROLLOUT_SEMAPHORE_OPTIONS.include?(class_semaphore)
            flash["error"] = "invalid semaphore for class"
            r.redirect "/rollouts"
          end
          klass_name, semaphore = class_semaphore.split(" - ", 2)
          klass = Object.const_get(klass_name)

          ds = klass
          ds = ds.where(location_id:) if location_id && klass.columns.include?(:location_id)
          ids = ds.select_map(:id)

          case increment
          when "increment-no-wait"
            increment = true
            wait = false
          when "decrement"
            increment = false
          else
            increment = true
            wait ||= true
          end

          Prog.const_get(prog).assemble(semaphore:, ids:, gap:, increment:, wait:)
        elsif prog == "RolloutBootImage"
          image_name, version, arch = typecast_params.nonempty_str!(%w[image_name version arch].freeze)
          concurrency = typecast_params.pos_int!("concurrency")
          exclude_minio_hosts = typecast_params.bool("exclude_minio_hosts")
          pause_stages = typecast_params.bool("pause_stages")

          unless Prog::DownloadBootImage::BOOT_IMAGE_SHA256.dig(image_name, arch, version)
            flash["error"] = "invalid version for boot image"
            r.redirect "/rollouts"
          end

          exclude_vm_host_ids = typecast_params.str("exclude_vm_host_ids").to_s.split(",").filter_map do |id|
            id = id.strip
            next if id.empty?
            uuid = UUID_REGEXP.match?(id) ? id : UBID.to_uuid(id)
            unless uuid
              flash["error"] = "invalid vm host id: #{id}"
              r.redirect "/rollouts"
            end
            uuid
          end

          Prog.const_get(prog).assemble(image_name:, version:, arch:, concurrency:,
            exclude_minio_hosts:, exclude_vm_host_ids:, pause_stages:)
        else
          Prog.const_get(prog).assemble
        end

        flash["notice"] = "Started rollout strand: #{st.ubid}"
        r.redirect "/rollouts"
      end

      strand_semaphore_action(strand_ds, ROLLOUT_PROGS,
        additional_semaphores: {"RolloutRhizome" => %w[github_runners_work].freeze, "RolloutBootImage" => %w[rollback].freeze})
    end

    r.on "remove-boot-images" do
      r.get true do
        @groups = BootImage
          .left_join(:vm_storage_volume, boot_image_id: Sequel[:boot_image][:id])
          .select_group(Sequel[:boot_image][:name], Sequel[:boot_image][:version])
          .select_append(
            Sequel.function(:count, Sequel[:boot_image][:id]).distinct.as(:image_count),
            Sequel.function(:count, Sequel[:vm_storage_volume][:id]).as(:volume_count),
          )
          .order(Sequel[:boot_image][:name], Sequel[:boot_image][:version])
          .naked
          .all
        view("remove_boot_images")
      end

      r.is "confirm" do
        @name, @version = typecast_params.nonempty_str!(%w[name version].freeze)

        images_ds = BootImage.where(name: @name, version: @version)
        # Only images with no active storage volumes (i.e. no active VM) can be removed.
        removable_ds = images_ds.exclude(id: VmStorageVolume.exclude(boot_image_id: nil).select(:boot_image_id))

        r.get do
          @total_count = images_ds.count
          @removable_count = removable_ds.count
          view("remove_boot_images_confirm")
        end

        r.post do
          image_ids = removable_ds.select_map(:id)
          Strand.import(
            [:id, :prog, :label, :stack],
            image_ids.map { [Strand.generate_uuid, "RemoveBootImage", "start", Sequel.pg_jsonb_wrap([{subject_id: it}])] },
          )
          flash["notice"] = "Scheduled removal of #{image_ids.length} boot image(s) for #{@name} #{@version}"
          r.redirect "/remove-boot-images"
        end
      end
    end

    r.on "local-e2e" do
      strand_ds = Strand.where(Sequel.like(:prog, "Test::%"))

      r.is do
        r.get do
          @strands = strand_ds.order(:prog, :id).eager(:semaphores).all
          view("local_e2e")
        end

        r.post do
          provider = typecast_params.nonempty_str("provider")
          raise "invalid local E2E provider" unless LOCAL_E2E_PROVIDERS.include?(provider)
          progs = typecast_params.array!(:nonempty_str, "progs")

          sts = if typecast_params.bool("loop")
            [Prog::Test::LocalE2eLoop.assemble(provider:, progs:)]
          else
            progs.map do |prog|
              Prog::Test::LocalE2eLoop.check_prog(prog)
              Prog::Test.const_get(prog).assemble(provider:, local_e2e: true)
            end
          end

          flash["notice"] = "Started local E2E strand(s): #{sts.map(&:ubid).join(" ")}"
          r.redirect
        end
      end

      strand_semaphore_action(strand_ds, LOCAL_E2E_PROGS + ["LocalE2eLoop"])
    end

    r.get "admin-list" do
      @admins = DB[:admin_account].select_order_map(:login)
      view("admin_list")
    end

    r.get "github-runner-usage" do
      @arch = (typecast_params.str("arch") == "arm64") ? "arm64" : "x64"

      vcpus_expr = Sequel.case(
        [[{label: "ubicloud"}, 2], [{label: "ubicloud-arm"}, 2]],
        Sequel.cast(Sequel.function(:regexp_replace, :label, '^.*(?:standard|premium)-(\d+).*$', '\1'), Integer),
      )

      runners = DB[:github_runner]
        .select(Sequel[:github_runner][:id], :installation_id, :vm_id, :allocated_at, vcpus_expr.as(:vcpus))
        .send((@arch == "arm64") ? :where : :exclude, Sequel[:label].like("%-arm%"))

      r_vcpus = Sequel[:r][:vcpus]
      v_vcpus = Sequel[:v][:vcpus]
      v_family = Sequel[:v][:family]
      count_f = ->(cond) { Sequel.function(:count).*.filter(cond) }
      standard_sizes = [2, 4, 8, 16, 30, 60]
      premium_sizes = [2, 4, 8, 16, 30]
      alien_sizes = [2, 4, 8, 16]

      quota_default = ProjectQuota.default_quotas[(@arch == "arm64") ? "GithubRunnerVCpuArm" : "GithubRunnerVCpu"]
      quota_expr = Sequel.function(
        :coalesce,
        Sequel[:pq][:value],
        Sequel.case(
          {"new" => quota_default["new_value"], "verified" => quota_default["verified_value"], "limited" => quota_default["limited_value"]},
          nil,
          Sequel[:p][:reputation],
        ),
      )

      @data = DB.from(runners.as(:r))
        .left_join(Sequel[:github_installation].as(:i), id: Sequel[:r][:installation_id])
        .left_join(Sequel[:project].as(:p), id: Sequel[:i][:project_id])
        .left_join(Sequel[:project_quota].as(:pq), project_id: Sequel[:p][:id], quota_id: quota_default["id"])
        .left_join(Sequel[:vm].as(:v), id: Sequel[:r][:vm_id])
        .select(
          Sequel[:i][:id],
          Sequel[:i][:name],
          Sequel.pg_jsonb(Sequel[:i][:allocator_preferences]).get("family_filter").contains(["premium"]).as(:prem),
          Sequel.cast(Sequel.pg_jsonb_op(Sequel[:p][:feature_flags]).get_text("spill_to_alien_runners"), :boolean).as(:spill),
          quota_expr.as(:quota),
        )
        .select_append(
          *standard_sizes.map { count_f.call(r_vcpus => it).as(:"r#{it}") },
          *{r: :runner, v: :vm}.flat_map { |k, prefix|
            [
              Sequel.function(:coalesce, Sequel.function(:sum, Sequel[k][:vcpus]).filter(~Sequel.expr(Sequel[k][:allocated_at] => nil)), 0).as(:"allocated_#{prefix}_vcpus"),
              Sequel.function(:coalesce, Sequel.function(:sum, Sequel[k][:vcpus]), 0).as(:"#{prefix}_vcpus"),
            ]
          },
          *standard_sizes.map { count_f.call(v_family => "standard", v_vcpus => it).as(:"s#{it}") },
          *premium_sizes.map { count_f.call(v_family => "premium", v_vcpus => it).as(:"p#{it}") },
          *alien_sizes.map { count_f.call(v_family.like("m%") & Sequel.expr(v_vcpus => it)).as(:"a#{it}") },
        )
        .group(Sequel[:i][:id], Sequel[:i][:name], :prem, :spill, :quota)
        .reverse(:runner_vcpus, :vm_vcpus)
        .all

      @family_utilization = VmHost.where(allocation_state: "accepting", location_id: [Location::GITHUB_RUNNERS_ID, Location::HETZNER_FSN1_ID, Location::HETZNER_HEL1_ID], arch: @arch)
        .select_group(:family)
        .select_append { round(sum(:used_cores) * 100.0 / sum(:total_cores), 2).cast(:float).as(:vcpu_util) }
        .select_append { round(sum(:used_hugepages_1g) * 100.0 / sum(:total_hugepages_1g), 2).cast(:float).as(:hugepage_util) }
        .to_hash(:family, [:vcpu_util, :hugepage_util])

      @spilled_vcpus = Vm.where(arch: @arch, boot_image: Prog::Github::GithubRunnerNexus::AWS_AMI_VERSIONS).sum(:vcpus) || 0

      view("github_runner_usage")
    end

    r.get "vm-host-usage" do
      @locations = Location.where(id: VmHost.select(:location_id)).select_order_map([:name, :id]).map { |name, id| [name, UBID.to_ubid(id)] }
      @archs = %w[x64 arm64].freeze
      @core_counts = VmHost.exclude(total_cores: nil).distinct.select_order_map(:total_cores)
      @states = %w[unprepared accepting draining].freeze

      @location_id = typecast_params.ubid("location_id")
      @arch = typecast_params.nonempty_str("arch")
      @cores = typecast_params.pos_int("cores")
      @state = typecast_params.nonempty_str("state")

      unless r.query_string.empty?
        storage_agg = DB[:storage_device]
          .select_group(:vm_host_id)
          .select_append(
            Sequel.function(:sum, :total_storage_gib).as(:total_storage),
            Sequel.function(:sum, :available_storage_gib).as(:available_storage),
          )

        boot_agg = DB[:boot_image]
          .select_group(:vm_host_id)
          .select_append(Sequel.function(:count, :name).distinct.as(:image_types))

        vm_agg = DB[:vm]
          .select_group(:vm_host_id)
          .select_append(Sequel.function(:count).*.as(:vm_count))

        ip4_agg = DB[:ipv4_address]
          .join(:address, [:cidr])
          .left_join(:assigned_vm_address, Sequel[:assigned_vm_address][:ip] => Sequel[:ipv4_address][:ip])
          .left_join(:assigned_host_address, Sequel[:assigned_host_address][:ip] => Sequel[:ipv4_address][:ip])
          .select_group(Sequel[:address][:routed_to_host_id])
          .select_append(
            Sequel.function(:count).*.as(:total_ip4),
            Sequel.function(:count).*.filter(Sequel[:assigned_vm_address][:ip] => nil, Sequel[:assigned_host_address][:ip] => nil).as(:available_ip4),
          )

        vmh = Sequel[:vm_host]
        vm_host_id = vmh[:id]
        ds = VmHost
          .join(Sequel[:location], id: vmh[:location_id])
          .left_join(storage_agg.as(:sd), vm_host_id:)
          .left_join(boot_agg.as(:bi), vm_host_id:)
          .left_join(ip4_agg.as(:ip), routed_to_host_id: vmh[:id])
          .left_join(vm_agg.as(:vm), vm_host_id:)
          .select(
            vmh[:id],
            Sequel[:location][:name].as(:location),
            vmh[:allocation_state],
            vmh[:data_center],
            vmh[:family],
            Sequel.function(:coalesce, Sequel[:vm][:vm_count], 0).as(:vm_count),
            vmh[:used_cores],
            vmh[:total_cores],
            vmh[:used_hugepages_1g],
            vmh[:total_hugepages_1g],
            Sequel.function(:coalesce, Sequel[:sd][:available_storage], 0).as(:available_storage),
            Sequel.function(:coalesce, Sequel[:sd][:total_storage], 0).as(:total_storage),
            Sequel.function(:coalesce, Sequel[:bi][:image_types], 0).as(:image_types),
            Sequel.function(:coalesce, Sequel[:ip][:available_ip4], 0).as(:available_ip4),
            Sequel.function(:coalesce, Sequel[:ip][:total_ip4], 0).as(:total_ip4),
          )
          .order(Sequel[:location][:name], vmh[:data_center], vmh[:family], vmh[:id])

        ds = ds.where(vmh[:location_id] => UBID.parse(@location_id).to_uuid) if @location_id
        ds = ds.where(vmh[:arch] => @arch) if @arch
        ds = ds.where(vmh[:total_cores] => @cores) if @cores
        ds = ds.where(vmh[:allocation_state] => @state) if @state

        @data = ds.map do |row|
          used_storage = row[:total_storage] - row[:available_storage]
          used_ip4 = row[:total_ip4] - row[:available_ip4]
          {
            ubid: UBID.to_ubid(row[:id]),
            location: row[:location],
            state: row[:allocation_state],
            datacenter: row[:data_center],
            family: row[:family],
            vms: row[:vm_count],
            cores: "#{row[:used_cores]} / #{row[:total_cores]}",
            hugepages: "#{row[:used_hugepages_1g]} / #{row[:total_hugepages_1g]}",
            storage_gib: "#{used_storage} / #{row[:total_storage]}",
            ip4: "#{used_ip4} / #{row[:total_ip4]}",
            image_types: row[:image_types],
          }
        end
      end

      view("vm_host_usage")
    end

    r.get "customer-usage" do
      count = Sequel.function(:count).*
      vm_agg = customer_vm_dataset
        .group(:project_id)
        .select(
          :project_id,
          Sequel.function(:sum, :vcpus).as(:total_vcpus),
          count.filter(pg_resource_id: nil, kubernetes_cluster_id: nil, github_runner_id: nil).as(:vm_count),
          count.filter(Sequel.~(pg_resource_id: nil)).as(:postgres_count),
          count.filter(Sequel.~(kubernetes_cluster_id: nil)).as(:kubernetes_count),
          count.filter(Sequel.~(github_runner_id: nil)).as(:runner_count),
        )

      spend_agg = DB[:invoice]
        .group(:project_id)
        .select(
          :project_id,
          Sequel.function(:sum, Sequel.cast(Sequel.pg_jsonb_op(:content).get_text("cost"), :numeric)).as(:total_spend),
        )

      email_agg = customer_email_dataset

      proj = Sequel[:project]
      total_vcpus = Sequel.function(:coalesce, Sequel[:va][:total_vcpus], 0)
      total_spend = Sequel.function(:coalesce, Sequel[:sa][:total_spend], 0)

      @data = DB[:project]
        .left_join(vm_agg.as(:va), project_id: proj[:id])
        .left_join(spend_agg.as(:sa), project_id: proj[:id])
        .left_join(email_agg.as(:ea), project_id: proj[:id])
        # Only projects with attributed resources or invoices are customers.
        .exclude(Sequel[:va][:project_id] => nil, Sequel[:sa][:project_id] => nil)
        .select(
          proj[:id],
          proj[:name],
          Sequel[:ea][:email],
          proj[:reputation],
          Sequel.function(:coalesce, Sequel[:va][:vm_count], 0).as(:vm_count),
          Sequel.function(:coalesce, Sequel[:va][:postgres_count], 0).as(:postgres_count),
          Sequel.function(:coalesce, Sequel[:va][:kubernetes_count], 0).as(:kubernetes_count),
          Sequel.function(:coalesce, Sequel[:va][:runner_count], 0).as(:runner_count),
          total_vcpus.as(:total_vcpus),
          total_spend.as(:total_spend),
        )
        .order(Sequel.desc(total_vcpus), Sequel.desc(total_spend), Sequel.function(:lower, proj[:name]))
        .map do |row|
          ubid = UBID.to_ubid(row[:id])
          name = project_label(row[:name], row[:email])
          {
            "Project" => table_link(name, "/model/Project/#{ubid}"),
            "Reputation" => row[:reputation],
            "VMs" => row[:vm_count],
            "PostgreSQL" => row[:postgres_count],
            "Kubernetes" => row[:kubernetes_count],
            "Runners" => row[:runner_count],
            "Total vCPUs" => row[:total_vcpus],
            "Total Spend" => "$%.2f" % row[:total_spend],
          }
        end

      view("customer_usage")
    end

    r.post "close-admin-account" do
      login = typecast_params.nonempty_str!("login")

      begin
        CloverAdmin.rodauth.close_account(account_login: login, session: {closer: rodauth.account_from_session[:login], ip: request.ip})
      rescue Rodauth::InternalRequestError
        flash["error"] = "Unable to close admin account for #{login.inspect}."
      else
        flash["notice"] = "Admin account #{login.inspect} closed."
      end

      r.redirect "/admin-list"
    end

    r.get "search" do
      @query = typecast_params.str!("q")
      prefix, term = @query.split(":", 2)

      terms = term&.split(",")&.map(&:strip)&.reject(&:empty?)
      if terms.nil? || terms.empty?
        flash.now["error"] = "Use prefix:term syntax to search (e.g. vm:name). Available prefixes: #{SEARCH_PREFIXES}"
        next view("search")
      end

      klass = UBID.class_for_ubid(prefix)
      columns = klass && SEARCH_QUERIES[klass.name]
      unless columns
        flash.now["error"] = "Unknown prefix: #{prefix}. Available prefixes: #{SEARCH_PREFIXES}"
        next view("search")
      end
      patterns = terms.map { "%#{klass.dataset.escape_like(it)}%" }
      @search_results = klass.grep(columns, patterns, case_insensitive: true).limit(11).all
      if @search_results.length > 10
        @truncated = @search_results.pop
      end

      if @search_results.length == 1
        obj = @search_results.first
        r.redirect("/model/#{obj.class.name}/#{obj.ubid}")
      end

      view("search")
    end

    r.root do
      if (ubid = typecast_params.ubid("id")) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif (uuid = typecast_params.uuid("id")) && (ubid = UBID.to_ubid(uuid)) && (klass = UBID.class_for_ubid(ubid))
        r.redirect("/model/#{klass.name}/#{ubid}")
      elsif (id = typecast_params.nonempty_str("id"))
        r.redirect("/search?q=#{Rack::Utils.escape(id)}")
      end

      @grouped_pages = Page.active
        .reverse(:created_at, :summary)
        .exclude(severity: "info")
        .left_join(:page_root_resource, page_id: :id)
        .to_hash_groups(:root_resource_id)
      @total_pages = @grouped_pages.flat_map(&:last).map!(&:id).uniq.size
      @classes = available_classes
      @info_pages = Page.active.where(severity: "info").reverse(:created_at).all

      view("index")
    end

    # :nocov:
    if Config.test?
      # :nocov:
      r.get("error") { raise }
    end
  end
end
