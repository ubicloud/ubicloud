# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Web::Vm

    r.on String do |vm_name|
      vm = @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first

      unless vm
        response.status = 404
        r.halt
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Vm:view", vm.id)

        @vm = serialize(vm, :detailed)

        view "vm/show"
      end

      r.on "firewall-rule" do
        r.post true do
          Authorization.authorize(@current_user.id, "Vm:Firewall:edit", vm.id)

          port_range = if r.params["port_range"].empty?
            [0, 65535]
          else
            r.params["port_range"].split("..").map(&:to_i)
          end

          pg_range = Sequel.pg_range(port_range.first..port_range.last)

          vm.firewalls.first.insert_firewall_rule(r.params["cidr"], pg_range)
          flash["notice"] = "Firewall rule is created"

          r.redirect "#{@project.path}#{vm.path}"
        end

        r.is String do |firewall_rule_ubid|
          r.delete true do
            Authorization.authorize(@current_user.id, "Vm:Firewall:edit", vm.id)
            fwr = FirewallRule.from_ubid(firewall_rule_ubid)
            unless fwr
              response.status = 404
              r.halt
            end

            fwr.destroy
            vm.incr_update_firewall_rules

            return {message: "Firewall rule deleted"}.to_json
          end
        end
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Vm:delete", vm.id)

        vm.incr_destroy

        return {message: "Deleting #{vm.name}"}.to_json
      end
    end
  end
end
