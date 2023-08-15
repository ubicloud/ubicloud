---
title: "Managed Service"
---

In this guide, you’re going to sign up to Ubicloud, create a virtual machine
(VM) and virtual network, and connect to the VM using SSH. For this dedicated
VM, you’ll get charged about 3x lower than you would with a public cloud
provider.

## Sign up and sign in

You can use Ubicloud without installing anything. When you do this, we pass
along the underlying provider's benefits to you, such as price or geolocation.

[https://console.ubicloud.com](https://console.ubicloud.com)

The first time you use Ubicloud, you’ll need to create a new account. Once you
do that and sign in, you’ll be directed to Ubicloud’s home page.


## Enter billing details

Ubicloud console’s homepage shows you available cloud services. It also lets you
collaborate with others using Projects, where you can invite new users and
define fine-grained permissions on resources.

By default, Ubicloud projects default to Hetzner as the bare metal hosting
provider. Each hosting provider has different prices, instance types, and
geolocation availability.

![Ubicloud Console Home](/img/ubicloud-homepage.png)

We require an active, valid credit card on file before you can create
resources. This is primarily a means to prevent abuse and ensure that we can
collect payment at the end of the month.

From the navigation menu on the left, choose Billing. Then, enter your credit
card information.


## Create Virtual Machine (VM)

On the navigation menu, choose Compute service and then click on New Virtual
Machine. This will take you to the VM creation page.

Here, you can choose your region, server size, and Linux distribution. You also
need to add your public SSH key so that you can connect to the VM after
creation.

By default, we create a private subnet for each VM. If you have an existing
private virtual network, you can also create this VM in that network. Each VM
gets a private IPv4 and IPv6 address in your virtual network. The VM also gets a
public IPv6 address for free and by default gets a public IPv4 address for a
small fee.

Once you’ve completed all required fields, click Create to create your VM. In
1-2 minutes, your VM should be ready to connect.

![Ubicloud Create VM](/img/ubicloud-create-vm.png)


## Connect to your VM

After your VM gets created, you can connect to it using SSH.

Copy the public IPv4 (or IPv6) address from your console. Then in your terminal,
simply type `ssh <user_name>@<ip_address>`. If you didn’t change the default
user name when creating the VM, this would be `ssh ubi@<ip_address>`

In summary, you created a VM in this quick start guide. The VM comes with local
block storage and has its own virtual network. The data gets encrypted at rest
and in transit; and you can collaborate with others using Attribute-Based Access
Control (ABAC). If you used the default provider, this VM will cost you 3x lower
than it would with AWS in the same region.
