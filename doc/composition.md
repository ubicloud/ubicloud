# Composition

In the asynchronous-work part of Clover, which encompasses Strands,
Progs, and some of the model classes, is a design focused on
composition.

I have found the limitation in previous efforts of mine generally
occurred around inflexibility in re-use of what could be orthogonal
code.

Each system since the first has moved in the direction of improving
this, not as a strategic matter, but because in delivering each
product for a few years, it was the area I perceived the most
friction.

In Clover, two meanings of this are most relevant:

* How the data model supports composition
* How "Progs" (background routines) compose with one another

## The Extensible Data Model

Entity records in Clover share primary key values and can be joined.
This allows flexible extension and re-use of code.

An example will clarify this abstract:

Both VMs and VM Hosts may be valid things to SSH to, and we'd like one
copy of low-level code handling SSH.

Look at the following pseudo-migration code:

    create_table(:sshable) do
      column :id, :uuid, primary_key: true
      column :host, :text
      column :private_key, :text
    end

    create_table(:vm_host) do
      foreign_key :id, :sshable, type: :uuid, primary_key: true
      [ ... other attributes ... ]
    end

This foreign key that's also a primary key enforces that every
`VmHost` has a companion `Sshable` record.

In principle, if these were the only two tables in the system, you
would combine them into a hypothetical `SshableVmHost` model that was
the output of a one-to-one join.  However, if at least *some* VMs were
relevant to run SSH to, we could easily re-use the SSH functionality
when adding another table like this:

    create_table(:vm) do
      column :id, :uuid, primary_key: true
      foreign_key :vm_host_id, :vm_host, type: :uuid
      [ ... other attributes ... ]
    end

Note that in this case, there is no foreign key from `Vm`'s `id`
column to `Sshable`, because a `Vm` being `Sshable` is optional.
However, for Vms where we want to be able to use ssh, we need only
create a `Sshable` record with the same `id` value.

With this, you gain a lot of power in re-use of existing code:

You could obtain the uptime for all VMs where you have ssh access like
so:

    # This is an inner join, so Vms with no Sshable get filtered out.
    Sshable.join(:vm, id: :id).map { _1.sshable.run("uptime") }

But, you could nearly as easily check how long the `vm_host` serving
each VM was running:

    Sshable.join(:vm, id: :id).map { _1.vm_host.sshable.run("uptime") }

Also attractive, you don't need to join through the data model to find
a one-to-one correlated record.  For example, given a UUID that is
a-priori known to be `Vm`, but only needing to do a ssh command, you
can dereference its ssh-relevant existence simply:

    Sshable[id]

Whereas, the more conventional, but inefficient and bloated way to do
things would be to chase a reference through a record, like so:

    Sshable[Vm[id].sshable_id]

While this traversal is often hidden by a Sequel association, it does
add extra queries and model loading that are unnecessary in some
cases.

## Progs

Progs are short for "Programs." But call them progs, so the
Clover-specific construct is implied.  Here's what one looks like, in
`prog/vm/prep_host.rb`. This prog prepares a host for running virtual
machines:

    class Prog::Vm::PrepHost < Prog::Base
      def sshable
        @sshable ||= Sshable[frame["vm_host_id"]]
      end

      def start
        sshable.cmd("sudo host/bin/prep_host.rb")
        pop "host prepared"
      end
    end

Prog have a number of methods inherited from `Prog::Base` that are
inspired by computer architecture or operating system concepts.

Computer architecture inspired:

* Jumps: `hop`
* Calls: `push`
* Return: `pop`
* The top stack frame: `frame`

The `push` and `pop` operations, along with their manipulations of the
stack, allow composition of progs.

Operating system call inspired:

* Spawn: `bud`
* Wait: `reap`
* Priority Donation: `donate`

`bud` and `reap` allow composition of progs, but in a concurrent
execution contexts.  These contexts are called `Strand`s, the name is
inspired by operating system or language runtime constructs like
Threads, Fibers, or Processes.

`donate` is also compositional, in the sense that processing time for
a prog is forwarded to child strands it had spawn and loaded with
other progs.

## Strands

`Strand` is a table-backed model responsible for loading and execute
progs, and hold their dynamic data, such as what entity in the system
the Prog is running (in the `stack` JSONB attribute), the `label`
(method) to execute, and exit and return values.

They also perform concurrency control, via leasing.  To satisfy this
mutual exclusion, a supervising concurrent mechanism should ensure the
process running the Stand is killed before the `LEASE_EXPIRATION` time
relative to when the Strand began running its workload.

Here are the attributes on a `Strand` and what they do or can be
compared to:

* `id`: comparable to the "pid" of a strand.
* `parent_id`: `NULL` if a root strand, set to a parent strand id otherwise
* `schedule`: the next time the strand is targeted to run.  It may run
  any time earlier, however.
* `lease`: a strand does not run if a lease is set and it has not yet expired.
* `prog`: the class name of a Prog to execute. the `Prog::` namespace
  is stripped before recording for easier reading.
* `label`: the method to call in the loaded Prog.
* `stack`: a JSONB array of where the first element is the top stack
           frame.  Each frame is a mapping value.
* `exitval`: if the prog in the strand signals it has completed, this
  records an exit value for the reaping process to inspect before
  deleting the Strand record.  Root strands delete themselves without
  waiting for a parent.
* `retval`: If the Strand has run `push`, the value passed to `pop`
  will be written here can be inspected by the prog that pushed
  another prog as a subroutine.

### The Nexus Prog & Strand Convention

A Nexus prog is, by convention, run in a root strand, and that strand
shares an `id` with at least one entity record.

Unlike most strands, the strand hosting the Nexus prog will last a
long time, generally from around the time of the creation of the
correlated entity record to deleting the record.  It controls the
life-cycle of an entity at the broadest level.

For example, `Prog::Vm::HostNexus` is one such prog.  Because it is
run in a strand sharing an `id` with an entity record, it can locate
the relevant entity record like this:

    def vm_host
      @vm_host ||= VmHost[strand.id]
    end

Also, in development and debugging, it's easy to locate and run the
prog in the strand:

    VmHost[id].strand.run

An interesting observation is that Strand records compose with other
entity records just like `Sshable` composes with `VmHost` in the
previous section:

    Sshable[id]
    VmHost[id]
    Strand[id]

    VmHost[id].strand.run
    VmHost[id].sshable.cmd("echo hi")

And so, though most strands are transient and don't share an `id` with
any entity, for Nexus-hosting Strands, that is not true: there are
other interesting records that join with their `id` value, and thus
they can be seen as an extension of other entity records.  Or,
alternatively, other entity records can be seen as an extension of the
Strand: there is, formally, no privileged record or type that is the
"true" existence of an entity, as they are all directly correlated
through `id`, though in practice, one will "feel" more specific than
the others.
