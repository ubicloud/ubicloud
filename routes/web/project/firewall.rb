# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "firewall") do |r|
    r.get true do
      authorized_firewalls = @project.firewalls_dataset.authorized(@current_user.id, "Firewall:view").all
      @firewalls = Serializers::Firewall.serialize(authorized_firewalls, {include_path: true})

      view "networking/firewall/index"
    end

    r.on "create" do
      r.get true do
        Authorization.authorize(@current_user.id, "Firewall:create", @project.id)
        authorized_subnets = @project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:edit").all
        @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
        view "networking/firewall/create"
      end
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Firewall:create", @project.id)
      Validation.validate_name(r.params["name"])

      fw = Firewall.create_with_id(
        name: r.params["name"],
        description: r.params["description"]
      )
      fw.associate_with_project(@project)

      ps = PrivateSubnet.from_ubid(r.params["private-subnet-id"])
      fw.associate_with_private_subnet(ps) if ps

      flash["notice"] = "'#{r.params["name"]}' is created"

      r.redirect "#{@project.path}#{Firewall[fw.id].path}"
    end

    r.on String do |fw_ubid|
      fw = Firewall.from_ubid(fw_ubid)

      unless fw
        response.status = 404
        r.halt
      end

      r.on "attach-subnet" do
        r.post true do
          Authorization.authorize(@current_user.id, "Firewall:view", fw.id)
          ps = PrivateSubnet.from_ubid(r.params["private-subnet-id"])
          unless ps
            flash["error"] = "Private subnet not found"
            response.status = 404
            r.redirect "#{@project.path}#{fw.path}"
          end

          Authorization.authorize(@current_user.id, "PrivateSubnet:edit", ps.id)

          fw.associate_with_private_subnet(ps)

          flash["notice"] = "Private subnet is attached to the firewall"

          r.redirect "#{@project.path}#{fw.path}"
        end
      end

      r.on "detach-subnet" do
        r.post true do
          Authorization.authorize(@current_user.id, "Firewall:view", fw.id)
          ps = PrivateSubnet.from_ubid(r.params["private-subnet-id"])
          unless ps
            flash["error"] = "Private subnet not found"
            response.status = 404
            r.redirect "#{@project.path}#{fw.path}"
          end

          Authorization.authorize(@current_user.id, "PrivateSubnet:edit", ps.id)

          fw.disassociate_from_private_subnet(ps)

          flash["notice"] = "Private subnet #{ps.name} is detached from the firewall"

          r.redirect "#{@project.path}#{fw.path}"
        end
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Firewall:view", fw.id)
        project_subnets = @project.private_subnets_dataset.authorized(@current_user.id, "PrivateSubnet:view").all
        attached_subnets = fw.private_subnets_dataset.all
        @attachable_subnets = Serializers::PrivateSubnet.serialize(project_subnets.reject { |ps| attached_subnets.map(&:id).include?(ps.id) })
        @firewall = Serializers::Firewall.serialize(fw, {detailed: true})

        view "networking/firewall/show"
      end

      r.on "firewall-rule" do
        r.post true do
          Authorization.authorize(@current_user.id, "Firewall:edit", fw.id)

          port_range = if r.params["port_range"].empty?
            [0, 65535]
          else
            Validation.validate_port_range(r.params["port_range"])
          end

          parsed_cidr = Validation.validate_cidr(r.params["cidr"])
          pg_range = Sequel.pg_range(port_range.first..port_range.last)

          fw.insert_firewall_rule(parsed_cidr.to_s, pg_range)
          flash["notice"] = "Firewall rule is created"

          r.redirect "#{@project.path}#{fw.path}"
        end

        r.is String do |firewall_rule_ubid|
          r.delete true do
            Authorization.authorize(@current_user.id, "Firewall:edit", fw.id)
            fwr = FirewallRule.from_ubid(firewall_rule_ubid)
            unless fwr
              response.status = 204
              r.halt
            end

            fw.remove_firewall_rule(fwr)

            return {message: "Firewall rule deleted"}.to_json
          end
        end
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Firewall:delete", fw.id)
        fw.private_subnets.map { Authorization.authorize(@current_user.id, "PrivateSubnet:edit", _1.id) }
        fw.destroy

        return {message: "Deleting #{fw.name}"}.to_json
      end
    end
  end
end
