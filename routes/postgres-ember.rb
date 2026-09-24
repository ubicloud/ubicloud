# frozen_string_literal: true

# The landing page a claim URL points at.
#
# An anonymous ember is handed out with a token and a URL rather than a
# project, because whoever created it does not have one yet. This page is
# where that token turns into an ember in a project they own: it sits outside
# the project scope because the whole point is that the project is not known
# until they pick one.
class Clover
  hash_branch("postgres-ember") do |r|
    r.on web?, "claim" do
      r.get true do
        no_authorization_needed
        @claim_token = typecast_params.nonempty_str("token")
        @projects = current_account.projects_dataset.where(:visible).order(:name).all
        view "postgres/ember_claim"
      end

      r.post true do
        @claim_token = typecast_params.nonempty_str!("token")
        @project = current_account.projects_dataset.with_pk(UBID.to_uuid(typecast_params.nonempty_str!("project")))
        check_found_object(@project)
        authorize("PostgresEmber:create", @project)

        handle_validation_failure("postgres/ember_claim") do
          @projects = current_account.projects_dataset.where(:visible).order(:name).all
        end

        ember = postgres_ember_claim(@claim_token)
        flash["notice"] = "Ember claimed."
        r.redirect ember
      end
    end
  end
end
