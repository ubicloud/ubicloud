package provider

import (
	"context"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/resource/schema"

	"github.com/ubicloud/terraform-provider-ubicloud/internal/planmodifiers"
)

// The upstream modifiers' Description() strings are identical across every type-specific
// package, so matching them verifies the schema regardless of which one codegen emitted.
const (
	descRequiresReplace    = "If the value of this attribute changes, Terraform will destroy and recreate the resource."
	descUseStateForUnknown = "Once set, the value of this attribute in state will not change."
)

func postgresPlanModifierDescriptions(ctx context.Context, attr schema.Attribute) []string {
	var descs []string
	switch a := attr.(type) {
	case schema.StringAttribute:
		for _, m := range a.PlanModifiers {
			descs = append(descs, m.Description(ctx))
		}
	case schema.BoolAttribute:
		for _, m := range a.PlanModifiers {
			descs = append(descs, m.Description(ctx))
		}
	case schema.Int64Attribute:
		for _, m := range a.PlanModifiers {
			descs = append(descs, m.Description(ctx))
		}
	case schema.Float64Attribute:
		for _, m := range a.PlanModifiers {
			descs = append(descs, m.Description(ctx))
		}
	case schema.ListNestedAttribute:
		for _, m := range a.PlanModifiers {
			descs = append(descs, m.Description(ctx))
		}
	case schema.MapAttribute:
		for _, m := range a.PlanModifiers {
			descs = append(descs, m.Description(ctx))
		}
	}
	return descs
}

func descsContain(descs []string, want string) bool {
	return descsIndex(descs, want) >= 0
}

func descsIndex(descs []string, want string) int {
	for i, d := range descs {
		if d == want {
			return i
		}
	}
	return -1
}

// Modifiers run in slice order threading the planned value: UseStateForUnknown must pin
// prior state before RequiresReplace compares, or an unset no-op plans a spurious replace.
func TestPostgresResourceModifierOrder(t *testing.T) {
	ctx := t.Context()
	s := PostgresResourceSchema(ctx)
	for _, name := range []string{"flavor", "parent"} {
		attr, ok := s.Attributes[name]
		if !ok {
			t.Fatalf("attribute %q not found in schema", name)
		}
		descs := postgresPlanModifierDescriptions(ctx, attr)
		usfu := descsIndex(descs, descUseStateForUnknown)
		rr := descsIndex(descs, descRequiresReplace)
		if usfu < 0 || rr < 0 {
			t.Errorf("attribute %q: expected both modifiers, got %v", name, descs)
			continue
		}
		if usfu > rr {
			t.Errorf("attribute %q: UseStateForUnknown must precede RequiresReplace, got %v", name, descs)
		}
	}
}

// ParentRefStability must sit between the two: it pins an imported replica's path-form
// state against a name-form config before RequiresReplace compares.
func TestPostgresParentRefStabilityWired(t *testing.T) {
	ctx := t.Context()
	descParentRef := planmodifiers.ParentRefStability().Description(ctx)
	s := PostgresResourceSchema(ctx)
	attr, ok := s.Attributes["parent"]
	if !ok {
		t.Fatal("attribute \"parent\" not found in schema")
	}
	descs := postgresPlanModifierDescriptions(ctx, attr)
	usfu := descsIndex(descs, descUseStateForUnknown)
	stab := descsIndex(descs, descParentRef)
	rr := descsIndex(descs, descRequiresReplace)
	if usfu < 0 || stab < 0 || rr < 0 {
		t.Fatalf("parent: expected UseStateForUnknown, ParentRefStability, and RequiresReplace; got %v", descs)
	}
	if usfu >= stab || stab >= rr {
		t.Errorf("parent: modifier order must be UseStateForUnknown < ParentRefStability < RequiresReplace; got %v", descs)
	}
}

// The API echoes parent only as the name path, so an id-configured parent cannot be
// reconciled client-side; the documented disposition is this note on the attribute.
func TestPostgresParentIdFormLimitationDocumented(t *testing.T) {
	ctx := t.Context()
	s := PostgresResourceSchema(ctx)
	attr, ok := s.Attributes["parent"]
	if !ok {
		t.Fatal("attribute \"parent\" not found in schema")
	}
	sa, ok := attr.(schema.StringAttribute)
	if !ok {
		t.Fatalf("parent: expected schema.StringAttribute, got %T", attr)
	}
	for _, want := range []string{"configure parent by name", "replace"} {
		if !strings.Contains(sa.MarkdownDescription, want) {
			t.Errorf("parent MarkdownDescription must document the id-form limitation (missing %q); got %q", want, sa.MarkdownDescription)
		}
	}
}

// Create-only immutables: path identity (project_id, location) plus inputs the PATCH body omits.
func TestPostgresResourceRequiresReplace(t *testing.T) {
	ctx := t.Context()
	s := PostgresResourceSchema(ctx)
	for _, name := range []string{
		"flavor", "parent", "restrict_by_default", "private_subnet_name", "project_id", "location",
	} {
		attr, ok := s.Attributes[name]
		if !ok {
			t.Fatalf("attribute %q not found in schema", name)
		}
		descs := postgresPlanModifierDescriptions(ctx, attr)
		if !descsContain(descs, descRequiresReplace) {
			t.Errorf("attribute %q: expected RequiresReplace plan modifier, got %v", name, descs)
		}
	}
}

// Pinning the stable computeds keeps a no-op plan equal to prior, so nothing churns
// to "known after apply".
func TestPostgresResourceUseStateForUnknown(t *testing.T) {
	ctx := t.Context()
	s := PostgresResourceSchema(ctx)

	pinned := []string{
		"id", "created_at", "ca_certificates",
		"flavor", "ha_type", "version",
		// A replica omits size/storage_size (inherited), so both must pin or they churn on re-plan.
		"size", "storage_size",
		"parent", "primary", "read_replica",
		"tags", "pg_config", "pgbouncer_config", "maintenance_window_start_at",
		// username is the serializer's literal constant "postgres", so pinning is always correct.
		"username",
		// Reads an in-place update never mutates; pinned with an Update-tail hold to drop
		// every-plan churn (the restore window moves every second, so the hold is required).
		"password", "firewall_rules", "earliest_restore_time", "latest_restore_time",
	}
	for _, name := range pinned {
		attr, ok := s.Attributes[name]
		if !ok {
			t.Fatalf("attribute %q not found in schema", name)
		}
		descs := postgresPlanModifierDescriptions(ctx, attr)
		if !descsContain(descs, descUseStateForUnknown) {
			t.Errorf("attribute %q: expected UseStateForUnknown plan modifier, got %v", name, descs)
		}
	}

	// Optional-only write-only inputs never go unknown; UseStateForUnknown would be a dead no-op.
	writeOnly := []string{"restrict_by_default", "private_subnet_name"}
	for _, name := range writeOnly {
		attr, ok := s.Attributes[name]
		if !ok {
			t.Fatalf("attribute %q not found in schema", name)
		}
		descs := postgresPlanModifierDescriptions(ctx, attr)
		if descsContain(descs, descUseStateForUnknown) {
			t.Errorf("attribute %q: expected NO UseStateForUnknown (write-only Optional-only), got %v", name, descs)
		}
	}

	// Lifecycle-varying: a rename moves hostname/connection_string, a resize converges the actual
	// sizes (target_* carry the request), failover swaps fallback_active.
	floating := []string{
		"hostname", "connection_string", "vm_size", "storage_size_gib",
		"target_vm_size", "target_storage_size_gib", "target_version",
		"target_server_count", "fallback_active",
	}
	for _, name := range floating {
		attr, ok := s.Attributes[name]
		if !ok {
			t.Fatalf("attribute %q not found in schema", name)
		}
		descs := postgresPlanModifierDescriptions(ctx, attr)
		if descsContain(descs, descUseStateForUnknown) {
			t.Errorf("attribute %q: expected NO UseStateForUnknown (convergence-sensitive), got %v", name, descs)
		}
	}
}

func postgresValidatorDescriptions(ctx context.Context, attr schema.Attribute) []string {
	var descs []string
	switch a := attr.(type) {
	case schema.StringAttribute:
		for _, v := range a.Validators {
			descs = append(descs, v.Description(ctx))
		}
	case schema.BoolAttribute:
		for _, v := range a.Validators {
			descs = append(descs, v.Description(ctx))
		}
	case schema.Int64Attribute:
		for _, v := range a.Validators {
			descs = append(descs, v.Description(ctx))
		}
	}
	return descs
}

// The read-replica create body accepts only {name, pg_config, pgbouncer_config, tags}; unvalidated, these
// would be silently dropped on dispatch. size/ha_type/version use state-aware ModifyPlan so restores stay mutable.
func TestPostgresWriteOnlyInputsConflictWithParent(t *testing.T) {
	ctx := t.Context()
	s := PostgresResourceSchema(ctx)
	for _, name := range []string{"restrict_by_default", "private_subnet_name"} {
		attr, ok := s.Attributes[name]
		if !ok {
			t.Fatalf("attribute %q not found in schema", name)
		}
		descs := postgresValidatorDescriptions(ctx, attr)
		found := false
		for _, d := range descs {
			if strings.Contains(d, "parent") {
				found = true
			}
		}
		if !found {
			t.Errorf("%s must carry a ConflictsWith(parent) validator (a read replica rejects it); validators=%v", name, descs)
		}
	}
}
