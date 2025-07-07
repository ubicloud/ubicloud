# frozen_string_literal: true

module Ubicloud
  # Ubicloud::Context instances are the root object used in Ubicloud's Ruby
  # SDK.  They provide access to the models, using the configured adapter.
  #
  # The following instance methods are defined via metaprogramming.  All
  # return instances of Ubicloud::ModelAdapter, for the related model.
  #
  # +firewall+ :: Ubicloud::Firewall
  # +inference_api_key+ :: Ubicloud::InferenceApiKey
  # +kubernetes_cluster+ :: Ubicloud::KubernetesCluster
  # +load_balancer+ :: Ubicloud::LoadBalancer
  # +postgres+ :: Ubicloud::Postgres
  # +private_subnet+ :: Ubicloud::PrivateSubnet
  # +vm+ :: Ubicloud::Vm
  class Context
    def initialize(adapter)
      @adapter = adapter
      @models = {}
    end

    {
      vm: Vm,
      postgres: Postgres,
      firewall: Firewall,
      private_subnet: PrivateSubnet,
      load_balancer: LoadBalancer,
      inference_api_key: InferenceApiKey,
      kubernetes_cluster: KubernetesCluster
    }.each do |meth, model|
      define_method(meth) { @models[meth] ||= ModelAdapter.new(model, @adapter) }
    end

    MODEL_PREFIX_MAP = {
      "vm" => Vm,
      "pg" => Postgres,
      "fw" => Firewall,
      "ps" => PrivateSubnet,
      "1b" => LoadBalancer,
      "ak" => InferenceApiKey,
      "kc" => KubernetesCluster
    }.freeze

    # Return a new model instance for the given id, assuming the id is properly
    # formatted.  Returns nil if the id is not properly formatted.  Does not
    # check with \Ubicloud to determine whether the object actually exists.
    def new(id)
      if id.is_a?(String) && (model = MODEL_PREFIX_MAP[id[0, 2]]) && model.id_regexp.match?(id)
        model.new(@adapter, id)
      end
    end

    # The same as #new, but checks that the object exists and you have access to it.
    def [](id)
      new(id)&.check_exists
    end
  end
end
