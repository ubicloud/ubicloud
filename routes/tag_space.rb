# frozen_string_literal: true

require "ulid"

class Clover
  class TagSpaceShadow
    attr_accessor :id, :name, :raw_id

    def initialize(tag_space)
      @id = ULID.from_uuidish(tag_space.id).to_s.downcase
      @raw_id = tag_space.id
      @name = tag_space.name
    end
  end

  class UserShadow
    attr_accessor :id, :email

    def initialize(user)
      @id = ULID.from_uuidish(user.id).to_s.downcase
      @email = user.email
    end
  end

  class AccessPolicyShadow
    attr_accessor :id, :name, :body

    def initialize(policy)
      @id = ULID.from_uuidish(policy.id).to_s.downcase
      @name = policy.name
      @body = policy.body.to_json
    end
  end

  hash_branch("tag-space") do |r|
    current_user = Account[rodauth.session_value]

    r.get true do
      @tag_spaces = current_user.tag_spaces.map { TagSpaceShadow.new(_1) }

      view "tag_space/index"
    end

    r.post true do
      tag_space = current_user.create_tag_space_with_default_policy(r.params["name"])

      r.redirect "/tag-space/#{TagSpaceShadow.new(tag_space).id}"
    end

    r.is "create" do
      r.get true do
        view "tag_space/create"
      end
    end

    r.on String do |tag_space_ulid|
      tag_space = TagSpace[id: ULID.parse(tag_space_ulid).to_uuidish]

      unless tag_space
        response.status = 404
        r.halt
      end

      @tag_space = TagSpaceShadow.new(tag_space)

      r.get true do
        Authorization.authorize(rodauth.session_value, "TagSpace:view", tag_space.id)

        view "tag_space/show_details"
      end

      r.delete true do
        Authorization.authorize(rodauth.session_value, "TagSpace:delete", tag_space.id)

        # If it has some resources, do not allow to delete it.
        if tag_space.access_tags_dataset.exclude(hyper_tag_table: [Account.table_name.to_s, TagSpace.table_name.to_s, AccessTag.table_name.to_s]).count > 0
          flash["error"] = "'#{tag_space.name}' tag space has some resources. Delete all related resources first."
          return {message: "'#{tag_space.name}' tag space has some resources. Delete all related resources first."}.to_json
        end

        DB.transaction do
          tag_space.access_tags.each { |access_tag| access_tag.applied_tags_dataset.delete }
          tag_space.access_tags_dataset.delete
          tag_space.access_policies_dataset.delete
          tag_space.delete
        end

        flash["notice"] = "'#{tag_space.name}' tag space is deleted."
        return {message: "'#{tag_space.name}' tag space is deleted."}.to_json
      end

      r.on "user" do
        Authorization.authorize(rodauth.session_value, "TagSpace:user", tag_space.id)

        r.get true do
          users_with_hyper_tag = tag_space.user_ids
          @users = Account.where(id: users_with_hyper_tag).map { UserShadow.new(_1) }

          view "tag_space/show_users"
        end

        r.post true do
          email = r.params["email"]
          user = Account[email: email]

          user&.associate_with_tag_space(tag_space)

          # TODO(enes): Move notifications to separate classes
          body = "You've been invited by #{current_user.email} to join the '#{tag_space.name}' tag space on Ubicloud."
          Mail.deliver do
            from Config.mail_from
            to email
            subject "Join #{tag_space.name} tag space on Ubicloud"

            text_part do
              body body
            end

            html_part do
              content_type "text/html; charset=UTF-8"
              body "<h3>#{body}</h3><a href='#{r.base_url}'>Go to Ubicloud</a>"
            end
          end

          flash["notice"] = "Invitation sent successfully to '#{email}'. You need to add some policies to allow new user to operate in the tag space.
                            If this user doesn't have account, they will need to create an account and you'll need to add them again."

          r.redirect "/tag-space/#{TagSpaceShadow.new(tag_space).id}/user"
        end

        r.is String do |user_ulid|
          user = Account[id: ULID.parse(user_ulid).to_uuidish]

          unless user
            response.status = 404
            r.halt
          end

          r.delete true do
            unless tag_space.user_ids.count > 1
              response.status = 400
              return {message: "You can't remove the last user from '#{tag_space.name}' tag space. Delete tag space instead."}.to_json
            end

            user.dissociate_with_tag_space(tag_space)

            return {message: "Removing #{user.email} from #{tag_space.name}"}.to_json
          end
        end
      end

      r.on "policy" do
        Authorization.authorize(rodauth.session_value, "TagSpace:policy", tag_space.id)

        r.get true do
          @policy = AccessPolicyShadow.new(tag_space.access_policies.first)

          view "tag_space/show_policies"
        end

        r.is String do |policy_ulid|
          policy = AccessPolicy[id: ULID.parse(policy_ulid).to_uuidish]

          unless policy
            response.status = 404
            r.halt
          end

          r.post true do
            policy.update(body: r.params["body"])

            flash["notice"] = "'#{policy.name}' policy updated for '#{tag_space.name}'"

            r.redirect "/tag-space/#{TagSpaceShadow.new(tag_space).id}/policy"
          end
        end
      end
    end
  end
end
