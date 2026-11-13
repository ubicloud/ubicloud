// Package planmodifiers holds custom plan modifiers, attached to generated schema attributes
// through the jq patch chain (config/plan_modifiers.jq) so they survive regeneration.
package planmodifiers

import (
	"context"
	"regexp"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
)

// The backend serializes parent as "/location/<loc>/postgres/<name>"; the capture is the
// name segment (names cannot contain a slash).
var parentPathRe = regexp.MustCompile(`^/location/[^/]+/postgres/([^/]+)$`)

// An id is always id-shaped (the openapi id pattern), so a non-id-shaped reference is
// unambiguously a name.
var postgresIdRe = regexp.MustCompile(`^pg[0-9a-hj-km-np-tv-z]{24}$`)

// Reduces the canonical response path to its name segment so it compares equal to a bare
// configured name. A bare id cannot be reduced (the path never carries the id), so the id
// form stays unequal to the path: an accepted limitation.
func normalizeParentRef(s string) string {
	s = strings.TrimSpace(s)
	if m := parentPathRe.FindStringSubmatch(s); m != nil {
		return m[1]
	}
	return s
}

// An imported replica holds the canonical path in state while config carries the name;
// without pinning to prior when both resolve to the same parent, RequiresReplace would
// compare path vs name and force a spurious replace. A genuine change still replaces.
type parentRefStability struct{}

func ParentRefStability() planmodifier.String {
	return parentRefStability{}
}

func (m parentRefStability) Description(_ context.Context) string {
	return "Keeps the prior parent reference when the planned value points at the same parent (name or id vs canonical path), so an imported read replica does not churn."
}

func (m parentRefStability) MarkdownDescription(ctx context.Context) string {
	return m.Description(ctx)
}

func (m parentRefStability) PlanModifyString(_ context.Context, req planmodifier.StringRequest, resp *planmodifier.StringResponse) {
	// No prior state (create) or an unresolved value: nothing to reconcile against.
	if req.StateValue.IsNull() || req.StateValue.IsUnknown() {
		return
	}
	if req.PlanValue.IsNull() || req.PlanValue.IsUnknown() {
		return
	}
	plan := strings.TrimSpace(req.PlanValue.ValueString())
	// An id-shaped reference may identify a different database than the state path's leaf;
	// a modifier cannot disambiguate without a network lookup, so let RequiresReplace decide
	// (over-replaces, never suppresses a real change).
	if postgresIdRe.MatchString(plan) {
		return
	}
	// Reduce only the state value: reducing the plan too would let a malformed path whose
	// leaf matches a different parent's name suppress a real replace.
	if normalizeParentRef(req.StateValue.ValueString()) == plan {
		resp.PlanValue = req.StateValue
	}
}
