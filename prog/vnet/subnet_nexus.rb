# frozen_string_literal: true

class Prog::Vnet::SubnetNexus < Prog::Base
  subject_is :private_subnet

  def self.assemble(project_id, name: nil, location_id: Location::HETZNER_FSN1_ID, ipv6_range: nil, ipv4_range: nil, allow_only_ssh: false, firewall_id: nil, firewall_name: nil, ipv4_range_size: nil, preferred_azs: [])
    unless (project = Project[project_id])
      fail "No existing project"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end
    if allow_only_ssh && firewall_id
      fail "Cannot specify both allow_only_ssh and firewall_id"
    end

    ubid = PrivateSubnet.generate_ubid
    id = ubid.to_uuid
    name ||= PrivateSubnet.ubid_to_name(ubid)

    Validation.validate_name(name)
    ipv4_range_size ||= (location.aws? ? PrivateSubnet::DEFAULT_AWS_SUBNET_PREFIX_LEN : PrivateSubnet::DEFAULT_SUBNET_PREFIX_LEN)
    ipv6_range ||= random_private_ipv6(location, project).to_s
    ipv4_range ||= random_private_ipv4(location, project, ipv4_range_size).to_s
    DB.transaction do
      ps = PrivateSubnet.create_with_id(id, name:, location_id: location.id, net6: ipv6_range, net4: ipv4_range, state: "waiting", project_id:)
      firewall_dataset = project.firewalls_dataset.where(location_id:)

      if firewall_id
        unless (firewall = firewall_dataset.first(Sequel[:firewall][:id] => firewall_id))
          fail "Firewall with id #{firewall_id} and location #{location.name} does not exist"
        end
      else
        port_range = allow_only_ssh ? 22..22 : 0..65535

        unless firewall_name
          firewall_name = "#{name[0, 55]}-default"
          # As is typical when checking before inserting, there is a race condition here with
          # a user concurrently manually creating a firewall with the same name.  However,
          # the worst case scenario is a bogus error message, and the user could try creating
          # the private subnet again.
          unless firewall_dataset.where(Sequel[:firewall][:name] => firewall_name).empty?
            firewall_name = "#{name[0, 47]}-default-#{Array.new(7) { UBID.from_base32(rand(32)) }.join}"
          end
        end

        firewall = Firewall.create(name: firewall_name, location_id: location.id, project_id:)
        DB.ignore_duplicate_queries do
          ["0.0.0.0/0", "::/0"].each { |cidr| FirewallRule.create(firewall_id: firewall.id, cidr:, port_range: Sequel.pg_range(port_range)) }
        end
      end
      firewall.associate_with_private_subnet(ps, apply_firewalls: false)

      prog = if location.aws?
        # Create PrivateSubnetAwsResource and pre-create AwsSubnet records for each AZ
        ps_aws_resource = PrivateSubnetAwsResource.create_with_id(ps.id)
        create_aws_subnet_records(ps, ps_aws_resource, location, ipv4_range_size, preferred_azs:)
        "Vnet::Aws::VpcNexus"
      elsif location.gcp?
        "Vnet::Gcp::SubnetNexus"
      else
        "Vnet::Metal::SubnetNexus"
      end
      Strand.create_with_id(id, prog:, label: "start")
    end
  end

  def self.create_aws_subnet_records(private_subnet, ps_aws_resource, location, ipv4_range_size, preferred_azs: [])
    vpc_ipv4 = private_subnet.net4

    ipv4_prefix = [ipv4_range_size + 8, 28].min

    available_azs = preferred_azs.empty? ? location.azs : preferred_azs
    azs = available_azs.sample(2**(ipv4_prefix - ipv4_range_size))

    raise "Not enough subnet space for even a single AZ. Use a range size <= 28" if azs.empty?

    azs.each_with_index do |az, idx|
      ipv4_cidr = vpc_ipv4.nth_subnet(ipv4_prefix, idx)
      # if the vpc size and the subnet sizes are the same, nth_subnet will
      # return nil. For example:
      # NetAddr::IPv4Net.parse("10.159.0.0/16").nth_subnet(16,0)
      # => nil
      ipv4_cidr = vpc_ipv4 if vpc_ipv4.netmask.prefix_len == ipv4_prefix && idx == 0

      AwsSubnet.create(
        private_subnet_aws_resource_id: ps_aws_resource.id,
        location_aws_az_id: az.id,
        ipv4_cidr: ipv4_cidr.to_s,
        ipv6_cidr: nil,  # Will be set when VPC is created
        subnet_id: nil   # Will be set when AWS subnet is created
      )
    end
  end

  def self.random_private_ipv6(location, project)
    until_random_ip("Could not find random IPv6 after 1000 iterations") { _random_private_ipv6(location, project) }
  end

  def self._random_private_ipv6(location, project)
    network_address = NetAddr::IPv6.new((SecureRandom.bytes(7) + 0xfd.chr).unpack1("Q<") << 64)
    network_mask = NetAddr::Mask128.new(64)
    selected_addr = NetAddr::IPv6Net.new(network_address, network_mask)

    selected_addr unless project.private_subnets_dataset[net6: selected_addr.to_s, location_id: location.id]
  end
  private_class_method :_random_private_ipv6

  def self.random_private_ipv4(location, project, cidr_size = 26)
    until_random_ip("Could not find random IPv4 after 1000 iterations") { _random_private_ipv4(location, project, cidr_size) }
  end

  def self._random_private_ipv4(location, project, cidr_size)
    raise ArgumentError, "CIDR size must be between 0 and 32" unless cidr_size.between?(0, 32)

    private_range = PrivateSubnet.random_subnet(cidr_size)
    addr = NetAddr::IPv4Net.parse(private_range)

    return unless addr.netmask.prefix_len < cidr_size

    selected_addr = addr.nth_subnet(cidr_size, SecureRandom.random_number(2**(cidr_size - addr.netmask.prefix_len) - 1).to_i + 1)

    failure_message = if PrivateSubnet::BANNED_IPV4_SUBNETS.any? { it.rel(selected_addr) }
      "Selected IPv4 subnet #{selected_addr} is banned"
    elsif (private_subnet = project.private_subnets_dataset[net4: selected_addr.to_s, location_id: location.id])
      "Selected IPv4 subnet #{selected_addr} is already in use by #{private_subnet.ubid}"
    end

    if failure_message
      Clog.emit(failure_message)
      return
    end

    selected_addr
  end
  private_class_method :_random_private_ipv4

  def self.until_random_ip(message)
    1000.times do |i|
      if (ip = yield)
        return ip
      end
    end
    raise message
  end
end
