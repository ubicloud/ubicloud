# Authorization

Authorization beyond the most basic is a feature that is missing almost entirely
from non-hyperscaler products in the cloud-adjacent space.

All three hyperscalers seem to be gradually moving towards attribute-based
access control (ABAC), which is explained best in general by
[Tailscale blog post](https://tailscale.com/blog/rbac-like-it-was-meant-to-be/).

You can see implementations of this, though they can be circuitous (by relying
on conditional expressions) relative to a clean-sheet ABAC design.
- [Amazon](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html)
- [Azure](https://learn.microsoft.com/en-us/azure/role-based-access-control/conditions-overview)
- [GCP](https://cloud.google.com/iam/docs/conditions-overview)

Ubicloud's authorization is going to deliver something about as powerful as IAM
seen on any of the hyperscalers. It's in active development. Expect to have
major adjustments.

Default tag space with all powers is created when new user account is created.
So new user may start to use our console right away without any knowledge about
authorization. After getting familiar with our services, they can create new
tag spaces, manage users, update policies etc.

## Design
A tag space is first and foremost a namespace for tags. Also, a tag space
provides a convenient hook to associate with billing. In this respect, it has a
lot in common with the Azure Subscription.

Access tag is the name of a tag and its tag space, so that two distinct tag
spaces could have a tag by the same name yet mean something distinct. When we
apply a access tag to a resources, applied tags are created. Applied tags
defines relations between resources and access tags. An access policy defines
who (subject) can do what (power) on what (object). It like a formula to connect
subjects and objects via powers. Any tag can be a subject or object. Powers are
like permissions.

```
                                               +---------------+
                        +---------------+      |  AppliedTags  |
    +----------+        |   AccessTag   |      |      id       |
    | TagSpace |        |      id       |<-+-->| access_tag_id |
+-->|    id    |<------>|  tag_space_id |  +-->|   tagged_id   |
|   +----------+        |     name      |  |   +---------------+
|                       |  hyper_tag_id |<-+
|  +--------------+     +---------------+  |
|  | AccessPolicy |                        |   +--------------+
+->| tag_space_id |                        |   |  Object ID   |
   |     name     |                        +-->|   User, Vm   |
   |     body     +----+                       | TagSpace etc.|
   +--------------+    |                       +--------------+
                       |
                       v
                   array({subjects, powers, objects})
```

### Hyper Tags
One way to associate a principal with some power over tags in a tag space is
hyper tagging. A way to implement hyper-tagging is to allow other kinds of
objects to also be a tag. In this case, the TagSpace, User, Vm record could
also be a tag.

Tags have some alternate life as another object (User, TagSpace, Vm, maybe
a Role record). To use a resource in access policy, it should be somehow
represented in this tag space. Resource are tagged with its access tag, so they
can be used in policy evaluation.

### Access Policy Language
Access policies have 3 main parts: subjects, powers, and objects. All of them
can be a single string or a list of strings. Access tags are used for subjects,
and objects. To use a tag in policy, it should have hyper-tag in that tag space.
Powers are predefined.

| Power           | Description                                            |
|-----------------|--------------------------------------------------------|
| Vm:view         | Grants permission to view Vm resources                 |
| Vm:create       | Grants permission to create Vm in TagSpace             |
| Vm:delete       | Grants permission to delete Vm                         |
| TagSpace:view   | Grants permission to view TagSpace details             |
| TagSpace:delete | Grants permission to delete TagSpace                   |
| TagSpace:user   | Grants permission to add/remove users to/from TagSpace |
| TagSpace:policy | Grants permission to update TagSpace's access policies |

#### Examples

User "test@test.com" can create a Vm in "default-tag-space" tag space.
```json
{
  "acls": [
    {
      "subjects": "User/test@test.com",
      "powers": "Vm:create",
      "objects": "TagSpace/default-tag-space"
    }
  ]
}
```

User "test@test.com" can view and delete Vms in "default-tag-space" tag space.
```json
{
  "acls": [
    {
      "subjects": "User/test@test.com",
      "powers": ["Vm:view", "Vm:delete"],
      "objects": "TagSpace/default-tag-space"
    }
  ]
}
```

User "test@test.com" can only view "vm1" and "vm2".
```json
{
  "acls": [
    {
      "subjects": "User/test@test.com",
      "powers": "Vm:view",
      "objects": ["Vm/vm1", "Vm/vm2"]
    }
  ]
}
```

User "test@test.com" can manage tag space users.
```json
{
  "acls": [
    {
      "subjects": "User/test@test.com",
      "powers": "TagSpace:user",
      "objects": "TagSpace/default-tag-space"
    }
  ]
}
```
