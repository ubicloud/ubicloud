# frozen_string_literal: true

# Project-scoped ember API and web UI (design doc 7.4).
#
# Embers are not location-scoped in the URL the way VMs are: an ember is
# meant to be obtained without thinking about where it lives, and the location
# is a create-time detail rather than part of its identity.
class Clover
  hash_branch(:project_prefix, "postgres-ember") do |r|
    r.post api?, "claim" do
      authorize("PostgresEmber:create", @project)
      postgres_ember_claim(typecast_params.nonempty_str!("claim_token"))
    end

    r.is do
      r.get api? do
        authorized = dataset_authorize(@project.embers_dataset, "PostgresEmber:view").select(:id)
        dataset = PostgresEmber.where(Sequel[:postgres_ember][:id] => authorized)
          .association_join(:ember).select_all(:postgres_ember).eager(ember: :location)
        paginated_result(dataset.reverse(Sequel[:ember][:created_at]), Serializers::PostgresEmber)
      end

      r.post do
        authorize("PostgresEmber:create", @project)
        # A rejected name or location has to come back as the form with the
        # message on it, not as an error page.
        handle_validation_failure("postgres/ember_create") { postgres_ember_create_options }
        postgres_ember_create
      end
    end

    r.on POSTGRES_EMBER_NAME_OR_UBID do |name, id|
      # Both the id and the name are the ember's, so the lookup is on it.
      filter = id ? {Sequel[:ember][:id] => id} : {Sequel[:ember][:name] => name}
      ember = PostgresEmber.where(id: @project.embers_dataset.where(filter).select(:id)).first
      check_found_object(ember)

      r.post %w[pause resume reset-password].freeze do |action|
        authorize("PostgresEmber:edit", ember.id)
        audit_log(ember, (action == "reset-password") ? "reset_superuser_password" : action)
        postgres_ember_action(ember, action)
        if api?
          Serializers::PostgresEmber.serialize(ember.reload, include_credentials: true)
        else
          flash["notice"] = POSTGRES_EMBER_ACTION_NOTICE.fetch(action)
          r.redirect ember
        end
      end

      r.is do
        r.get do
          authorize("PostgresEmber:view", ember.id)
          if api?
            Serializers::PostgresEmber.serialize(ember, include_credentials: true)
          else
            @ember = ember
            @hostname_suffix = Config.postgres_gateway_hostname_suffix
            view "postgres/ember_show"
          end
        end

        r.delete do
          authorize("PostgresEmber:delete", ember.id)
          audit_log(ember, "destroy")
          ember.incr_destroy
          204
        end
      end

      # The web UI has no DELETE verb, so destruction is a POST to /delete,
      # the way it is for every other resource here.
      r.post web?, "delete" do
        authorize("PostgresEmber:delete", ember.id)
        audit_log(ember, "destroy")
        ember.incr_destroy
        flash["notice"] = "Ember will be deleted"
        r.redirect "#{@project.path}/ember"
      end
    end
  end

  POSTGRES_EMBER_ACTION_NOTICE = {
    "pause" => "Ember will be paused",
    "resume" => "Ember resumed",
    "reset-password" => "Superuser password reset",
  }.freeze
end
