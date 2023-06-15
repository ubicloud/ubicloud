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

Default project with all permission is created when new user account is created.
So new user may start to use our console right away without any knowledge about
authorization. After getting familiar with our services, they can create new
projects, manage users, update policies etc.

## Design
A project is first and foremost a namespace for tags. Also, a project provides
a convenient hook to associate with billing. In this respect, it has a
lot in common with the Azure Subscription.

Access tag is the name of a tag and its project, so that two distinct tag
spaces could have a tag by the same name yet mean something distinct. When we
apply a access tag to a resources, applied tags are created. Applied tags
defines relations between resources and access tags. An access policy defines
who (subject) can do what (action) on what (object). It like a formula to connect
subjects and objects via actions. Any tag can be a subject or object.

```
                                               +---------------+
                        +---------------+      |  AppliedTags  |
    +----------+        |   AccessTag   |      |      id       |
    |  Project |        |      id       |<-+-->| access_tag_id |
+-->|    id    |<------>|   project_id  |  +-->|   tagged_id   |
|   +----------+        |     name      |  |   +---------------+
|                       |  hyper_tag_id |<-+
|  +--------------+     +---------------+  |
|  | AccessPolicy |                        |   +--------------+
+->|  project_id  |                        |   |  Object ID   |
   |     name     |                        +-->|   User, Vm   |
   |     body     +----+                       | Project etc. |
   +--------------+    |                       +--------------+
                       |
                       v
                   array({subjects, actions, objects})
```

### Hyper Tags
One way to associate a principal with some power over tags in a project is
hyper tagging. A way to implement hyper-tagging is to allow other kinds of
objects to also be a tag. In this case, the Project, User, Vm record could
also be a tag.

Tags have some alternate life as another object (User, Project, Vm, maybe
a Role record). To use a resource in access policy, it should be somehow
represented in this project. Resource are tagged with its access tag, so they
can be used in policy evaluation.

### Access Policy Language
Access policies have 3 main parts: subjects, actions, and objects. All of them
can be a single string or a list of strings. Access tags are used for subjects,
and objects. To use a tag in policy, it should have hyper-tag in that project.
Actions are predefined.

| Action          | Description                                            |
|-----------------|--------------------------------------------------------|
| Vm:view         | Grants permission to view Vm resources                 |
| Vm:create       | Grants permission to create Vm in Project              |
| Vm:delete       | Grants permission to delete Vm                         |
| Project:view    | Grants permission to view Project details              |
| Project:delete  | Grants permission to delete Project                    |
| Project:user    | Grants permission to add/remove users to/from Project  |
| Project:policy  | Grants permission to update Project's access policies  |

#### Examples

User "test@test.com" can create a Vm in "default-project" project.
```json
{
  "acls": [
    {
      "subjects": "User/test@test.com",
      "actions": "Vm:create",
      "objects": "Project/default-project"
    }
  ]
}
```

User "test@test.com" can view and delete Vms in "default-project" project.
```json
{
  "acls": [
    {
      "subjects": "User/test@test.com",
      "actions": ["Vm:view", "Vm:delete"],
      "objects": "Project/default-project"
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
      "actions": "Vm:view",
      "objects": ["Vm/vm1", "Vm/vm2"]
    }
  ]
}
```

User "test@test.com" can manage project's users.
```json
{
  "acls": [
    {
      "subjects": "User/test@test.com",
      "actions": "Project:user",
      "objects": "Project/default-project"
    }
  ]
}
```
