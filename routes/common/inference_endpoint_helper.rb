# frozen_string_literal: true

class Routes::Common::InferenceEndpointHelper < Routes::Common::Base
  def list
    if @mode == AppMode::API
      dataset = project.inference_endpoints_dataset
      dataset = dataset.where(location: @location) if @location
      result = dataset.authorized(@user.id, "InferenceEndpoint:view").paginated_result(
        start_after: @request.params["start_after"],
        page_size: @request.params["page_size"],
        order_column: @request.params["order_column"]
      )

      {
        items: Serializers::InferenceEndpoint.serialize(result[:records]),
        count: result[:count]
      }
    else
      inference_endpoints = Serializers::InferenceEndpointPrivate.serialize(project.inference_endpoints_dataset.authorized(@user.id, "InferenceEndpoint:view").all, {include_path: true})
      @app.instance_variable_set(:@private_inference_endpoints, inference_endpoints)
      @app.view "inference-endpoint/private/index"
    end
  end

  def list_public
    if @mode == AppMode::API
      {
        items: [],
        count: 0
      }
    else
      inference_endpoints = Serializers::InferenceEndpointPublic.serialize(InferenceEndpoint.where(public: true).where(visible: true).all, {include_path: true})
      @app.instance_variable_set(:@public_inference_endpoints, inference_endpoints)
      @app.view "inference-endpoint/public/index"
    end
  end

  def post(name: nil)
    Authorization.authorize(@user.id, "InferenceEndpoint:create", project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless project.has_valid_payment_method?

    required_parameters = ["model_name"]
    required_parameters << "name" << "location" if @mode == AppMode::WEB
    allowed_optional_parameters = ["min_replicas", "max_replicas"]
    request_body_params = Validation.validate_request_body(params, required_parameters, allowed_optional_parameters)
    min_replicas, max_replicas = Validation.validate_inference_endpoint_replicas(request_body_params["min_replicas"], request_body_params["max_replicas"])
    model = Validation.validate_inference_endpoint_model(request_body_params["model_name"], @location)

    # TODO: validate quotas

    st = Prog::Ai::InferenceEndpointNexus.assemble(
      project_id: project.id,
      location: @location,
      boot_image: model["boot_image"],
      name: name,
      vm_size: model["vm_size"],
      storage_volumes: model["storage_volumes"],
      model_name: request_body_params["model_name"],
      engine: model["engine"],
      engine_params: model["engine_params"],
      min_replicas: min_replicas,
      max_replicas: max_replicas
    )

    if @mode == AppMode::API
      Serializers::InferenceEndpoint.serialize(st.subject)
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      @request.redirect "#{project.path}#{InferenceEndpoint[st.id].path}"
    end
  end

  def get
    Authorization.authorize(@user.id, "InferenceEndpoint:view", @resource.id)
    if @mode == AppMode::API
      Serializers::InferenceEndpoint.serialize(@resource)
    else
      @app.instance_variable_set(:@pg, Serializers::InferenceEndpoint.serialize(@resource, {include_path: true}))
      @app.view "inference-endpoint/private/show"
    end
  end

  def delete
    Authorization.authorize(@user.id, "InferenceEndpoint:delete", @resource.id)
    @resource.incr_destroy
    response.status = 204
    @request.halt
  end
end
