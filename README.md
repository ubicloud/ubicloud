<p align="center">
  <img src="https://github.com/user-attachments/assets/779e73bd-c260-4729-8430-c630628f1b6b">
</p>


# Ubicloud [![CI](https://github.com/ubicloud/ubicloud/actions/workflows/ci.yml/badge.svg)](https://github.com/ubicloud/ubicloud/actions/workflows/ci.yml) [![Build](https://github.com/ubicloud/ubicloud/actions/workflows/build.yml/badge.svg)](https://github.com/ubicloud/ubicloud/actions/workflows/build.yml) <a href="https://app.greptile.com/repo/ubicloud/ubicloud"><img src="https://img.shields.io/badge/learn_with-greptile-%091B12?color=%091B12" alt="Learn this repo using Greptile"></a>

Ubicloud is an open source cloud that can run anywhere. Think of it as an open alternative
to cloud providers, like what Linux is to proprietary operating systems.

Ubicloud provides IaaS cloud features on bare metal providers, such as Hetzner, Leaseweb, 
and AWS Bare Metal. You can set it up yourself on these providers or you can use our 
[managed service](https://console.ubicloud.com).

## Quick start

### Managed platform

You can use Ubicloud without installing anything. When you do this, we pass along the 
underlying provider's benefits to you, such as price or location.

https://console.ubicloud.com

### Build your own cloud

You can also build your own cloud. To do this, start up Ubicloud's control plane and 
connect to its cloud console.

```
git clone git@github.com:ubicloud/ubicloud.git

# Generate secrets for demo
./demo/generate_env

# Run containers: db-migrator, app (web & respirate), postgresql
docker-compose -f demo/docker-compose.yml up

# Visit localhost:3000
```

The control plane is responsible for cloudifying bare metal Linux machines.
The easiest way to build your own cloud is to lease instances from one of those
providers. For example: https://www.hetzner.com/sb

Once you lease instance(s), update the `.env` file with the following environment
variables:
- `HETZNER_USER`
- `HETZNER_PASSWORD`
- `HETZNER_SSH_PUBLIC_KEY`
- `HETZNER_SSH_PRIVATE_KEY`

Then, run the following script for each instance to cloudify it.
Currently, the script cloudifies bare metal instances leased from Hetzner.
After you cloudify your instances, you can provision and manage cloud
resources on these machines.

```
# Enter hostname/IP and provider
docker exec -it ubicloud-app ./demo/cloudify_server
```

Later when you create VMs, Ubicloud will assign them IPv6 addresses. If your ISP 
doesn't support IPv6, please use a VPN or tunnel broker such as Mullvad or Hurricane 
Electric's https://tunnelbroker.net/ to connect. Alternatively, you could lease
IPv4 addresses from your provider and add them to your control plane.

## Why use it

Public cloud providers like AWS, Azure, and Google Cloud have made life easier for 
start-ups and enterprises. But they are closed source, have you rent computers 
at a huge premium, and lock you in. Ubicloud offers an open source alternative, 
reduces your costs, and returns control of your infrastructure back to you. All 
without sacrificing the cloud's convenience.

Today, AWS offers about two hundred cloud services. Ultimately, we will implement 
10% of the cloud services that make up 80% of that consumption.

Example workloads and reasons to use Ubicloud today include:

* You have an ephemeral workload like a CI/CD pipeline (we're integrating with
GitHub Actions), or you'd like to run compute/memory heavy tests. Our managed
cloud is ~3x cheaper than AWS, so you save on costs.

* You want a portable and simple app deployment service like 
[Kamal](https://github.com/basecamp/kamal). We're moving Ubicloud's control plane
from Heroku to Kamal; and we want to provide open and portable services for
Kamal's dependencies in the process.

* You have bare metal machines sitting somewhere. You'd like to build your own
cloud for portability, security, or compliance reasons.

## Status

You can provide us your feedback, get help, or ask us questions regarding your
Ubicloud installations in the [Community Forum](https://github.com/ubicloud/ubicloud/discussions).

We follow an established architectural pattern in building public cloud services. 
A control plane manages a data plane, where the data plane leverages open source 
software.  You can find our current cloud components / services below.

* **Elastic Compute**: Our control plane communicates with Linux bare metal servers
using SSH. We use [Cloud
Hypervisor](https://github.com/cloud-hypervisor/cloud-hypervisor) as our virtual
machine monitor (VMM); and each instance of the VMM is contained within Linux
namespaces for further isolation / security.

* **Networking**: We use [IPsec](https://en.wikipedia.org/wiki/IPsec) tunneling to
establish an encrypted and private network environment. We support IPv4 and IPv6 in
a dual-stack setup and provide both public and private networking. For security,
each customer’s VMs operate in their own networking namespace. For
[firewalls](https://www.ubicloud.com/blog/ubicloud-firewalls-how-linux-nftables-enables-flexible-rules)
and [load balancers](https://www.ubicloud.com/blog/ubicloud-load-balancer-simple-and-cost-free),
we use Linux nftables.

* **Block Storage, non replicated**: We use Storage Performance Development Toolkit
([SPDK](https://spdk.io)) to provide virtualized block storage to VMs. SPDK enables
us to add enterprise features such as snapshot and replication in the future. We
follow security best practices and encrypt the data encryption key itself.

* **Attribute-Based Access Control (ABAC)**: With ABAC, you can define attributes,
roles, and permissions for users and give them fine-grained access to resources. You
can read more about our [ABAC design here](doc/authorization.md).

* **What's Next?**: We're planning to work on a managed K8s or metrics/monitoring
service next. If you have a workload that would benefit from a specific cloud
service, please get in touch with us through our [Community
Forum](https://github.com/ubicloud/ubicloud/discussions).

* Control plane: Manages data plane services and resources. This is a Ruby program
that stores its data in Postgres. We use the [Roda](https://roda.jeremyevans.net/)
framework to serve HTTP requests and [Sequel](http://sequel.jeremyevans.net/) to
access the database. We manage web authentication with
[Rodauth](http://rodauth.jeremyevans.net/). We communicate with data plane servers
using SSH, via the library [net-ssh](https://github.com/net-ssh/net-ssh). For our
tests, we use [RSpec](https://rspec.info/).

* Cloud console: Server-side web app served by the Roda framework. For the visual
design, we use [Tailwind CSS](https://tailwindcss.com) with components from
[Tailwind UI](https://tailwindui.com). We also use jQuery for interactivity.

If you’d like to start hacking with Ubicloud, any method of obtaining Ruby and Postgres 
versions is acceptable. If you have no opinion on this, our development team uses `asdf-vm` 
as [documented here in detail](DEVELOPERS.md).

[Greptile](https://greptile.com/) provides an AI/LLM that indexes
Ubicloud's source code [can answer questions about
it](https://learnthisrepo.com/ubicloud).

## FAQ

### Do you have any experience with building this sort of thing?

Our founding team comes from Azure; and worked at Amazon and Heroku before that.
We also have start-up experience. We were co-founders and founding team members 
at [Citus Data](https://github.com/citusdata/citus), [which got acquired by 
Microsoft](https://news.ycombinator.com/item?id=18990469).

### How is this different than OpenStack?

We see three differences. First, Ubicloud is available as a managed service (vs boxed
software). This way, you can get started in minutes rather than weeks. Since Ubicloud
is designed for multi-tenancy, it comes with built-in features such as encryption 
at rest and in transit, virtual networking, secrets rotation, etc.

Second, we're initially targeting developers. This -we hope- will give us fast feedback 
cycles and enable us to have 6 key services in GA form in the next two years. OpenStack 
is still primarily used for 3 cloud services.

Last, we're designing for simplicity. With OpenStack, you pick between 10 hypervisors, 
10 S3 implementations, and 5 block storage implementations. The software needs to work 
in a way where all of these implementations are compatible with each other. That leads
to consultant-ware. We'll take a more opinionated approach with Ubicloud.
