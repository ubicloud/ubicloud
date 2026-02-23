# frozen_string_literal: true

class Clover < Roda
  if Config.unfrozen_test? && ENV["FORCE_AUTOLOAD"] == "1"
    class DirectModelAccess < StandardError; end

    module ModelProxyAccess
      def is_a?(klass)
        klass = klass.sequel_model if ModelProxy === klass
        super
      end
    end
    Object.include ModelProxyAccess

    class ModelProxy < BasicObject
      ALLOWED_CALLS = {
        ::ActionTag => [:options_for_project],
        ::ApiKey => [:create_inference_api_key, :create_personal_access_token, :project_id_for_personal_access_token],
        ::DiscountCode => [:first],
        ::FirewallRule => [:cidr_for_source_type, :range_for_port_type, :port_options, :source_options],
        ::GithubInstallation => [:with_github_installation_id],
        ::GithubRepository => [:cache_size_limit],
        ::InferenceEndpoint => [:is_public],
        ::InferenceRouterModel => [:where],
        ::Invoice => [:blob_storage_client],
        ::LoadBalancer => [:stack_options],
        ::Location => [:for_project, :postgres_locations, :visible_or_for_project],
        ::MachineImage => [:for_project, :where],
        ::LockedDomain => [:with_pk],
        ::ObjectTag => [:options_for_project],
        ::PaymentMethod => [:fraud?],
        ::PostgresResource => [:default_flavor, :default_version, :ha_type_none, :generate_postgres_options, :maintenance_hour_options, :partner_notification_flavors, :postgres_flavors],
        ::PostgresServer => [:victoria_metrics_client],
        ::SubjectTag => [:admin_tag?, :options_for_project, :subject_id_map_for_project_and_accounts],
        ::Vm => [:from_runtime_jwt_payload]
      }.freeze
      ALLOWED_CALLS.each_value(&:freeze)

      def initialize(model)
        @model = model
        @allow = [:===, :create, :create_with_id, :new, :new_with_id, :ubid_format, :ubid_type]
        if (allow = ALLOWED_CALLS[model])
          @allow.concat(allow)
        end
        @allow.freeze
      end

      def method_missing(m, ...)
        if @allow.include?(m)
          @model.send(m, ...)
        # :nocov:
        else
          ::Kernel.raise DirectModelAccess, "Calling #{@model}.#{m} directly in Clover is not allowed"
        end
      end

      def respond_to_missing?(m, _include_all)
        @allow.include?(m)
      end
      # :nocov:

      def sequel_model
        @model
      end
    end

    def self.models_loaded
      skip_models = %w[Account OidcProvider].freeze
      Sequel::Model.subclasses.each do |model|
        name = model.name
        next unless /\A[A-Za-z0-9]+\z/.match?(name) && !skip_models.include?(name)
        const_set(name, ModelProxy.new(model))
      end
    end
  # :nocov:
  else
    def self.models_loaded
      # nothing
    end
  end
  # :nocov:
end
