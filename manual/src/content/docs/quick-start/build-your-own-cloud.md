---
title: "Build Your Own Cloud"
---

In this guide, you’re going to build your own cloud on a bare metal
provider. You’re going to set up Ubicloud’s control plane, lease bare metal
instance(s) for the data plane, and cloudify those bare metal instances. Once
cloudified, you can use elastic compute, virtual networking, and (local) block
storage services.


## Create your control plane

Ubicloud follows an established architectural pattern in building public cloud
services. A control plane manages a data plane, where the data plane leverages
open-source software. First, clone the Ubicloud project and initialize the
control plane on your local environment. Then, connect to the cloud console.

```
git clone git@github.com:ubicloud/ubicloud.git

# Generate secrets for demo
./demo/generate_env

# Run containers: db-migrator, app (web & respirate), postgresql
docker-compose -f demo/docker-compose.yml up

# Visit localhost:3000
```

Once you’ve initialized the control plane, create a new user and sign into the
cloud console.


## Lease bare metal instance(s) for data plane

You’ll know need to lease instance(s) for the data plane. The easiest way to do this is to lease an instance from a bare metal provider. Hetzner has server auctions available, where you pay monthly for bare metal: https://www.hetzner.com/sb


## Cloudify your instance(s)

Run the following script for each instance you’d like to cloudify. By default,
the script cloudifies bare metal instances leased from Hetzner. After you
cloudify your instance(s), you can provision and manage resources.

```
# Enter hostname/IP and provider, and install SSH key as instructed by script
docker exec -it ubicloud-app ./demo/cloudify_server
```


## Create Virtual Machine (VM)

Now, you can log into the console at localhost:3000 and create VMs. Ubicloud
will create each VM in a virtual network and assign them private IPv4/IPv6
addresses. It will also assign a public IPv6 address to the VM.

If your ISP doesn't support IPv6, please use a VPN or tunnel broker such Mullvad
or Hurricane Electric's https://tunnelbroker.net/ to connect. Alternatively, you
could lease IPv4 addresses from your provider and add them to your control
plane.

In summary, you built your own cloud on a bare metal provider in this quick
start guide. You could then use standard cloud services that come with Ubicloud,
such as compute, virtual networking, and local block storage.
