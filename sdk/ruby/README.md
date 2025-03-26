# Ubicloud

`Ubicloud` is the official Ruby SDK for accessing Ubicloud. It is designed for
programmer happiness, just as Ruby itself is.  Methods in this SDK send
request's to Ubicloud's API.

## Installation

```ruby
gem install ubicloud
```

## Usage

`Ubicloud` uses an object-oriented SDK.  The first step is creating an
appropriate context.  If you are going to use the SDK to manage a single
Ubicloud project, it is recommended you set the context to a constant:

```ruby
UBI = Ubicloud.new(:net_http, token: "YOUR_API_TOKEN", project_id: "pj...")
```

The positional argument to `Ubicloud.new` is the adapter type to use.
Currently, the `net_http` adapter is recommended.  The `token` keyword
argument is the Ubicloud API token used for requests.  The `project_id`
keyword argument is the project that will be accessed. You can also use a
`base_uri` keyword if you are using a self-hosted version of Ubicloud (or
any version not hosted by Ubicloud).

The documentation below assumes you are storing the SDK context in the
`UBI` constant.

### Object Types

`Ubicloud` currently supports manipulating 5 types of objects:

* Firewall (`UBI.firewall`): Firewalls
* LoadBalancer (`UBI.load_balancer`): Load balancers
* Postgres (`UBI.postgres`): PostgreSQL databases
* PrivateSubnet (`UBI.private_subnet`): Private subnets
* Vm (`UBI.vm`): Virtual machines

### Methods Supported By All Types

`Ubicloud` tries to keep the API consistent across supported types, to make it
easier to use.  

#### Listing Objects

`UBI.type.list` is used to retrieve a list of objects you have access to
inside the project:

```ruby
UBI.firewall.list
UBI.load_balancer.list
UBI.postgres.list
UBI.private_subnet.list
UBI.vm.list
```

To only retrieve objects in a specific location, you can use a `location`
keyword argument:

```ruby
UBI.vm.list(location: "eu-central-h1")
```

`UBI.type.list` returns a array of objects.  For example `UBI.vm.list`
returns an array of `Ubicloud::Vm` objects.  Each of these objects is partially
populated.  If you need to fully populate the object, you can call `info`
on the object:

```ruby
vm = UBI.vm.list.first
vm.info
```

#### Creating An Object

`UBI.type.create` is used to create a new object.  It requires the `location`
and `name` keyword arguments.  Additional parameters, which may be required or
optional per object type, are also provided as keyword arguments:

```ruby
UBI.firewall.create(location: "eu-central-h1", name: "my-firewall")

UBI.firewall.create(location: "eu-central-h1", name: "other-firewall",
  description: "My other firewall")

UBI.vm.create(location: "eu-central-h1", name: "my-vm",
  public_key: File.read("~/.ssh/authorized_keys"))
```

Additional required keyword arguments for each type:

* LoadBalancer: `private_subnet_id`, `algorithm`, `src_port`,
  `dst_port`, `health_check_protocol`, `stack`
* Vm: `public_key`

Optional keyword arguments for each type:

* Firewall: `description`
* LoadBalancer: `health_check_endpoint`
* Postgres: size, `storage_size`, `ha_type`, `version`, `flavor`
* PrivateSubnet: `firewall_id`
* Vm: `size`, `storage_size`, `unix_user`, `boot_image`, `enable_ip4`,
  `private_subnet_id`

#### Retrieving An Object

If you know the object you want to retrieve, instead of picking it out of a
list, you can retrieve it directly.  If you know the id of the object, you
can provide that to `UBI.[]`:

```ruby
UBI["vm345678901234567890123456"]
```

This instantiates an object of the appropriate class, and checks that the
object exists and you have access to it.  If you provide an invalid id, or
you do not have access to the object, the method returns `nil`.

If you know the object already exists, and do not need to check, you can
call `UBI.new`:

```ruby
UBI.new("vm345678901234567890123456")
```

In addition to looking up objects by id, you can look them up by using
`location/name`.  However, in this case you need to specify the type of
the object, since it cannot be inferred:

```ruby
vm = UBI.vm["eu-central-h1/my-vm"]
```

Like `UBI.[]`, this will check the object exists and you have access to it.
If you do not want to check, you can use `new`:

```ruby
vm = UBI.vm.new("eu-central-h1/my-vm")
```

When using `UBI.new` or `UBI.type.new`, the created object may not
actually exist in Ubicloud.  You can call `info` on the returned object
to check that it exists. If it does not exist, an `Ubicloud::Error`
exception will be raised.

#### Destroying An Object

You can call `destroy` to destroy an object:

```ruby
vm = UBI["vm345678901234567890123456"]
vm.destroy
```

Note that there is no way to recover an object that has been destroyed. You
should only use this method if you are sure you no longer need the object.

### Type-Specific Methods

In addition to the methods supported for all types, each type also supports
methods specific to that type.

#### Firewall

##### `add_rule`

`Firewall#add_rule` adds a firewall rule to allow access to the given port(s)
from a given IP address range:

```ruby
fw = UBI["fw345678901234567890123456"]

# Allow access to all ports
fw.add_rule("1.2.3.0/24")

# Allow access to specific port
fw.add_rule("1.2.0.0/16", start_port: 5432)

# Allow access to port range
fw.add_rule("1.2.3.0/24", start_port: 10000, end_port: 11000)
```

##### `delete_rule`

`Firewall#delete_rule` removes a previously added firewall rule.  You must
provide the firewall rule id (which you can retrieve by inspecting the
firewall rules):

```ruby
fw = UBI["fw345678901234567890123456"]

rule_id = fw.firewall_rules.first[:id]
fw.delete_rule(rule_id)
```

##### `attach_subnet`

`Firewall#attach_subnet` attaches an existing private subnet to the firewall:

```ruby
fw = UBI["fw345678901234567890123456"]
ps = UBI.private_subnet.list.first

# Using PrivateSubnet object
fw.attach_subnet(ps)

# Using private subnet id
fw.attach_subnet(ps.id)
```

##### `detach_subnet`

`Firewall#detach_subnet` detaches an existing private subnet to the firewall:

```ruby
fw = UBI["fw345678901234567890123456"]
ps = UBI.private_subnet.list.first

# Using PrivateSubnet object
fw.detach_subnet(ps)

# Using private subnet id
fw.detach_subnet(ps.id)
```

#### LoadBalancer

##### `attach_vm`

`LoadBalancer#attach_vm` attaches an existing virtual machine to the load
balancer:

```ruby
lb = UBI["1b345678901234567890123456"]
vm = UBI.vm.list.first

# Using Vm object
lb.attach_vm(vm)

# Using virtual machine id
lb.attach_vm(vm.id)
```

##### `detach_vm`

`LoadBalancer#detach_vm` detaches an existing virtual machine from the load
balancer:

```ruby
lb = UBI["1b345678901234567890123456"]
vm = UBI.vm.list.first

# Using Vm object
lb.detach_vm(vm)

# Using virtual machine id
lb.detach_vm(vm.id)
```

##### `update`

`LoadBalancer#update` updates a load balancer's parameters. It requires the
following keyword arguments: `algorithm`, `src_port`, `dst_port`,
`health_check_endpoint`, `vms`.

The `vms` argument should be an array of virtual machines attached to the load
balancer.  The method will attach and detach virtual machines to the load
balancer as needed so that the list of attached virtual machines matches the
array given.

```ruby
lb = UBI["1b345678901234567890123456"]
vm = UBI.vm.list.first

lb.update(algorithm: "https", src_port: 8443, dst_port: 443,
  health_check_endpoint: "/up", vms: [vm])
```

#### Postgres

##### `add_firewall_rule`

`Postgres#add_firewall_rule` adds a firewall rule to allow access to the
PostgreSQL port (5432) from a given IP address range:

```ruby
pg = UBI["pg345678901234567890123456"]
pg.add_firewall_rule("1.2.3.0/24")
```

##### `delete_firewall_rule`

`Postgres#delete_firewall_rule` removes a previously added firewall rule.
You must provide the firewall rule id (which you can retrieve by inspecting
the database firewall rules):

```ruby
pg = UBI["pg345678901234567890123456"]

rule_id = pg.firewall_rules.first[:id]
pg.delete_firewall_rule(rule_id)
```

##### `add_metric_destination`

`Postgres#add_metric_destination` adds a destination for the database metrics.
It requires the following keyword arguments: `username`, `password`, `url`:

```ruby
pg = UBI["pg345678901234567890123456"]
pg.add_metric_destination(username: "foo", password: "bar",
  url: "https://metrics.example.com/add_metric")
```

##### `delete_metric_destination`

`Postgres#delete_metric_destination` removes a previously added metric
destination.  You must provide the metric destination id (which you can
retrieve by inspecting the database metric destinations):

```ruby
pg = UBI["pg345678901234567890123456"]

md_id = pg.metric_destinations.first[:id]
pg.delete_metric_destination(md_id)
```

##### `restart`

`Postgres#restart` schedules a restart of the PostgreSQL database:

```ruby
pg = UBI["pg345678901234567890123456"]
pg.restart
```

##### `reset_superuser_password`

`Postgres#reset_superuser_password` schedules a reset of the superuser
(`postgres`) password for the PostgreSQL database. 

```ruby
pg = UBI["pg345678901234567890123456"]
pg.reset_superuser_password('some-secret-password')
```

##### `restore`

`Postgres#restore` schedules a restore a previous version of the receiver database to a
new database at the given restore target.  It requires the following keyword
arguments: `name` (of restored database), `restore_target`

```ruby
pg = UBI["pg345678901234567890123456"]

# Create a copy of the database as of 10 minutes ago
pg.restore(name: "restored-database", restore_target: Time.now - 600)
```

#### PrivateSubnet

##### `connect`

`PrivateSubnet#connect` connects two private subnets (it does not matter which
is the receiver and which is the argument):

```ruby
ps1, ps2 = UBI.private_subnet.list

# Using PrivateSubnet object
ps1.connect(ps2)

# Using private subnet id
ps1.connect(ps2.id)
```

##### `disconnect`

`PrivateSubnet#connect` disconnects two private subnets (it does not matter
which is the receiver and which is the argument):

```ruby
ps1, ps2 = UBI.private_subnet.list

# Using PrivateSubnet object
ps1.disconnect(ps2)

# Using private subnet id
ps1.disconnect(ps2.id)
```

#### Vm

##### `restart`

`Vm#restart` schedules a restart of an existing virtual machine:

```ruby
vm = UBI["vm345678901234567890123456"]
vm.restart
```

### Associations

Model instances support associations:

```ruby
# LoadBalancer instance
lb = UBI["lb345678901234567890123456"]

# PrivateSubnet instance
ps = lb.subnet

# Firewall instance
fw = ps.firewalls.first

# Add a rule to that firewall instance
fw.add_rule("1.2.3.0/24")
```

## License

MIT

## Support

For support, please open a GitHub discussion:
https://github.com/ubicloud/ubicloud/discussions/new?category=q-a
