# frozen_string_literal: true

class CloverRuntime
  hash_branch("ai") do |r|
    if (inference_endpoint_replica = InferenceEndpointReplica[vm_id: @vm.id]).nil?
      fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization headerXX")
    end

    inference_endpoint = inference_endpoint_replica.inference_endpoint
    r.on "inference-endpoint" do
      r.post true do
        if inference_endpoint.public
          {
            public: true,
            projects:
          Project.all # TODO more filtering and proper quotas
            .select { _1.get_ff_inference_endpoint }
            .reject { _1.api_key_pair.nil? }
            .map do
              {
                ubid: _1.ubid,
                keys: [_1.api_key_pair.key1_hash, _1.api_key_pair.key2_hash],
                quota_rps: 1.0,
                quota_tps: 100.0
              }
            end
          }
        else
          {
            public: false,
            projects:
          [{
            ubid: inference_endpoint.project.ubid,
            keys: [inference_endpoint.api_key_pair.key1_hash, inference_endpoint.api_key_pair.key2_hash],
            quota_rps: 1000000.0,
            quota_tps: 1000000.0
          }]
          }
        end
      end
    end
  end
end
