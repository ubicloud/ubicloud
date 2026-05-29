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
        ::Account => [:[], :open_with_email, :generate_uuid],
        ::ActionTag => [:options_for_project],
        ::ApiKey => [:create_inference_api_key, :create_personal_access_token, :project_id_for_personal_access_token],
        ::DiscountCode => [:first],
        ::FirewallRule => [:cidr_for_source_type, :protocol_and_range_for_port_type, :port_options, :source_options],
        ::GithubInstallation => [:with_github_installation_id],
        ::GithubRepository => [:cache_size_limit],
        ::InferenceEndpoint => [:is_public],
        ::InferenceRouterModel => [:where],
        ::Invoice => [:blob_storage_client],
        ::LoadBalancer => [:stack_options],
        ::Location => [:for_project, :postgres_locations, :visible_or_for_project],
        ::LockedDomain => [:with_pk],
        ::ObjectTag => [:options_for_project],
        ::OidcProvider => [:[], :name_for_ubid, :identity_name_hash, :with_pk!],
        ::ParseableResource => [:client_for_project],
        ::PaymentMethod => [:fraud?],
        ::PostgresResource => [:default_flavor, :default_version, :ha_type_none, :generate_postgres_options, :maintenance_hour_options, :partner_notification_flavors, :postgres_flavors],
        ::PostgresServer => [:victoria_metrics_client],
        ::SubjectTag => [:admin_tag?, :options_for_project, :subject_id_map_for_project_and_accounts],
        ::Vm => [:from_runtime_jwt_payload],
      }.freeze
      ALLOWED_CALLS.each_value(&:freeze)
      ALLOWED_MODELS = [
        ::AccessControlEntry,
        ::ActionType,
        ::BillingInfo,
        ::Firewall,
        ::GithubCacheEntry,
        ::GithubRunner,
        ::KubernetesCluster,
        ::KubernetesNodepool,
        ::LocationCredentialAws,
        ::MachineImage,
        ::MachineImageVersion,
        ::PostgresInitScript,
        ::PostgresLogDestination,
        ::PostgresMetricDestination,
        ::PrivateSubnet,
        ::Project,
        ::SshPublicKey,
        ::Strand,
        ::UsageAlert,
      ].freeze
      DEFAULT_ALLOW = [:===, :create, :create_with_id, :new, :new_with_id, :ubid_format, :ubid_type].freeze

      def self.setup(model)
        if (allow = ALLOWED_CALLS[model])
          new(model, (DEFAULT_ALLOW + allow).freeze)
        elsif ALLOWED_MODELS.include?(model)
          new(model, DEFAULT_ALLOW)
        end
      end

      def initialize(model, allow)
        @model = model
        @allow = allow
      end

      def method_missing(m, ...)
        if @allow.include?(m)
          @model.send(m, ...)
        else
          ::Kernel.raise DirectModelAccess, "Calling #{@model}.#{m} directly in Clover is not allowed"
        end
      end

      # :nocov:
      def respond_to_missing?(m, _include_all)
        @allow.include?(m)
      end
      # :nocov:

      def sequel_model
        @model
      end
    end

    def self.models_loaded
      Sequel::Model.descendants.each do |model|
        name = model.name
        if /\A[A-Za-z0-9]+\z/.match?(name)
          if (model_proxy = ModelProxy.setup(model))
            const_set(name, model_proxy)
          else
            autoload(name, "./vendor/hidden_model")
          end
        end
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
