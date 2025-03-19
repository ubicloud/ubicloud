# frozen_string_literal: true

module Ubicloud
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
      load_balancer: LoadBalancer
    }.each do |meth, model|
      define_method(meth) { @models[meth] ||= ModelAdapter.new(model, @adapter) }
    end

    MODEL_PREFIX_MAP = {
      "vm" => Vm,
      "pg" => Postgres,
      "fw" => Firewall,
      "ps" => PrivateSubnet,
      "1b" => LoadBalancer
    }.freeze

    def [](id)
      if id.is_a?(String) && (model = MODEL_PREFIX_MAP[id[0, 2]]) && model.id_regexp.match?(id)
        model.new(@adapter, id)
      end
    end
  end
end
