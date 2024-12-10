# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-playground") do |r|
    unless @project.get_ff_inference_ui
      response.status = 404
      r.halt
    end

    r.get true do
      @inference_endpoints = inference_endpoint_list
      @inference_tokens = inference_token_list
      view "inference/playground/index"
    end
  end
end
