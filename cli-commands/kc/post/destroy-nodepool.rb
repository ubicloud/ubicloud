# frozen_string_literal: true

class UbiCli
  on("kc").run_on("destroy-nodepool") do
    desc "Destroy a nodepool of a Kubernetes cluster"

    options("ubi kc (location/kc-name | kc-id) destroy-nodepool [options] (np-name | np-id)", key: :destroy_nodepool) do
      on("-f", "--force", "do not require confirmation")
    end

    args 1

    run do |np_ref, opts, cmd|
      check_no_slash(np_ref, "invalid nodepool name", cmd)
      if opts.dig(:destroy_nodepool, :force) || opts[:confirm] == np_ref
        sdk_object.destroy_nodepool(np_ref)
        response("Nodepool, if it exists, is now scheduled for destruction")
      elsif opts[:confirm]
        invalid_confirmation <<~END
          ! Confirmation of nodepool name not successful.
        END
      else
        require_confirmation("Confirmation", <<~END)
          Destroying this nodepool is not recoverable.
          Enter the following to confirm destruction of the nodepool: #{np_ref}
        END
      end
    end
  end
end
