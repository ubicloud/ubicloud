# frozen_string_literal: true

class CloverRuntime
  hash_branch("ai") do |r|
    if (inference_endpoint_replica = InferenceEndpointReplica[vm_id: @vm.id]).nil?
      fail CloverError.new(400, "InvalidRequest", "invalid JWT format or claim in Authorization headerXX")
    end

    inference_endpoint = inference_endpoint_replica.inference_endpoint
    r.on "inference-endpoint" do
      r.post true do
        replica_ubid = r.params["replica_ubid"]
        public_inference_endpoint = r.params["public_inference_endpoint"]
        projects = r.params["projects"]
        fail CloverError.new(400, "InvalidRequest", "Incorrect payload") if replica_ubid.nil? || public_inference_endpoint.nil? || projects.nil?
        fail CloverError.new(400, "InvalidRequest", "Unexpected replica ubid") unless replica_ubid == inference_endpoint_replica.ubid
        fail CloverError.new(400, "InvalidRequest", "Unexpected request from private inference endpoint") unless inference_endpoint.public

        puts projects # TODO consume billing info

        {
          projects:
            Project.all # TODO more filtering and proper quotas
              # .select { _1.get_ff_inference_endpoint }
              .reject { _1.api_key_pair.nil? }
              .map do
                {
                  ubid: _1.ubid,
                  api_keys: [_1.api_key_pair.key1_hash, _1.api_key_pair.key2_hash],
                  quota_rps: 1.0,
                  quota_tps: 100.0
                }
              end
        }
      end
    end
  end
end
