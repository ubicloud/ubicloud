# Ubicloud

Ubicloud is an open source portable cloud. It provides IaaS cloud features in
common hardware and network environments, such as those available in Hetzner,
OVH, Datapacket, Equinix Metal, AWS Bare Metal, and others.

## Quick start

Start up Ubicloud's control plane and connect to its dashboard. The first time
you connect, you'll need to sign up.

```
# Generate secrets for demo
./demo/generate_env

# Run containers: web, respirate, postgresql
docker-compose -f demo/docker-compose.yml up

# Visit localhost:3000
```

The control plane is responsible for cloudifying bare metal Linux machines.
When you click to "Create a Virtual Machine", you'll see example providers. The
easiest way to build your own cloud is to lease instances from one of those
providers. For example: https://www.hetzner.com/sb

Once you do, click add VM Hosts from the cloud dashboard. This will cloudify
your Linux machines. Ubicloud can then provision and manage resources for
cloud services on these machines.

![Cloudify Linux Machine](https://github.com/ubicloud/clover/assets/2545443/23bcba42-35ba-4e91-93ce-6b7e009d3522)

Please note that Ubicloud uses SSH to manage Linux machines; and needs access
to the SSH key you're using in accessing these machines. Also, once you create
VMs, Ubicloud will assign them IPv6 addresses. If your ISP doesn't support IPv6,
please use a VPN such Mullvad or contact us to allocate your IPv4 address space.

## Status

Ubicloud is in public alpha. You can provide us your feedback, get help, or ask
us to support your network environment in the 
[Community Forum](https://github.com/ubicloud/clover/discussions).

You can also find our cloud services and their statuses below.

- [Elastic Compute](doc/vm.md): Public Alpha
- [Virtual Networking](doc/net.md): Public Alpha
- Blob Storage via MinIO Hosting: Draft
- Attribute-Based Access Control (ABAC) Authorization: Draft
- IPv4 Support: Draft

## Why use it

In the past decade, there has been a massive shift to the cloud. AWS, Azure, and
Google Cloud offer services that make life easier for start-ups and
enterprises alike. But these offerings have you rent computers at a premium. If
you want to run your own hardware or even just have a clear migration path to do
so in the future, you need to consider how locked in you are to these commercial
platforms. Ideally, before the bills swallow your business.

Ubicloud aims to run common cloud services anywhere. Whether that's low-cost
bare metal providers like Hetzner or OVH, or on your colocated hardware. This
gives you enormous portability. With that portability, you can benefit from cost
savings, avoid vendor lock-in, and meet your security & compliance needs.

Today, AWS provides about two hundred cloud services. Ultimately, we will
implement 10% of the cloud services that make up 80% of that consumption.

## How it works

Ubicloud follows an established architectural pattern in building public
cloud services. A control plane manages a data plane, where the data plane
usually leverages open source software.

We implement our control plane in Ruby and have it communicate with Linux bare
metal servers using SSH. We use Cloud Hypervisor to run virtual machines; and
implement virtualized networking using IPsec. Our blob storage system is a
managed MinIO cluster. We use SPDK for network block devices.

For the control plane, we have a Ruby program that connects to Postgres. We base
the source code organization on the [Roda-Sequel
Stack](https://github.com/jeremyevans/roda-sequel-stack) with some
modifications. As the name indicates, we use
[Roda](https://roda.jeremyevans.net/) for HTTP code and
[Sequel](http://sequel.jeremyevans.net/) for database queries.

We manage web authentication with [RodAuth](http://rodauth.jeremyevans.net/).

We communicates with servers using SSH, via the library
[net-ssh](https://github.com/net-ssh/net-ssh).

For our tests, we use [RSpec](https://rspec.info/). We also automatically lint
and format the code using [RuboCop](https://rubocop.org/).

For the web console's visual design, we use [Tailwind
CSS](https://tailwindcss.com) with components from [Tailwind
UI](https://tailwindui.com). We also use jQuery for interactivity.

Any method of obtaining of Ruby and Postgres versions is acceptable,
but if you have no opinion on this, our development team uses `asdf-vm` as
[documented here in detail.](DEVELOPERS.md)
