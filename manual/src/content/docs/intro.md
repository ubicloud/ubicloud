---
title: "Ubicloud Introduction"
---

# Overview

## What is Ubicloud?

Ubicloud is an open, free, and portable cloud. Think of it as an alternative to
public cloud providers, like what Linux is to proprietary operating systems.

Ubicloud offers infrastructure-as-a-service (IaaS) features on providers that
lease bare metal instances, such as Hetzner, OVH, and AWS Bare Metal. It’s also
available as a managed service.


## Why Ubicloud?

Cloud services like AWS, Azure, and Google Cloud made life easier for start-ups
and enterprises. But they are closed source, have you rent computers at a huge
premium, and lock you in. Ubicloud offers an open alternative, reduces your
costs, and returns control of your infrastructure back to you. All without
sacrificing from the cloud's convenience.

Today, AWS offers about two hundred cloud services. Ultimately, we will
implement 10% of the cloud services that make up 80% of that consumption.

Example workloads/reasons to use Ubicloud today include:

* You have an ephemeral workload like a CI/CD pipeline (we're integrating with
GitHub Actions), or you'd like to run compute/memory heavy tests. Our managed
cloud is ~3x cheaper than AWS, so you save on costs.

* You want a portable and simple app deployment service like MRSK. We're moving
Ubicloud's control plane from Heroku to MRSK; and we want to provide open and
portable services for MRSK's dependencies in the process.

* You have bare metal machines sitting somewhere. You'd like to build your own
cloud for portability, security, or compliance reasons.



## License

Ubicloud is available for free under Elastic License 2.0 (ELv2). You can use,
extend, or deploy it as long as you don’t provide it as a manage service to
another party. You can access our GitHub repo here:
https://github.com/ubicloud/ubicloud


## Product

Ubicloud is in public alpha. You can provide us with feedback, get help, or ask
us to support your bare metal provide by sending us an email at
[support@ubicloud.com](support@ubicloud.com)

Existing cloud services include the following:

* Elastic Compute - Provision, use, and delete isolated VMs on bare metal
* Virtual Networking - Public and private networking. IPv4 and IPv6. Encryption
in transit
* Block Storage (non-replicated) - Block devices with encryption at rest
* Attributed-Based Access Control (ABAC) - Define roles for different
  users. Provide fine-grained access control

Additional components that are available with our open license include:

* Control plane - Communicates with the data plane using SSH and manages
resources
* Cloud console - A dashboard for users to use cloud services
