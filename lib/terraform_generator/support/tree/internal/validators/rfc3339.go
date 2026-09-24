// Package validators holds custom validators, attached to generated schema attributes
// through the jq patch chain (config/plan_modifiers.jq) so they survive regeneration.
package validators

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
)

type rfc3339Validator struct{}

func (rfc3339Validator) Description(_ context.Context) string {
	return "value must be an RFC 3339 timestamp, for example 2026-06-24T11:00:00Z"
}

func (v rfc3339Validator) MarkdownDescription(ctx context.Context) string {
	return v.Description(ctx)
}

func (rfc3339Validator) ValidateString(_ context.Context, req validator.StringRequest, resp *validator.StringResponse) {
	if req.ConfigValue.IsNull() || req.ConfigValue.IsUnknown() {
		return
	}
	if _, err := time.Parse(time.RFC3339, strings.TrimSpace(req.ConfigValue.ValueString())); err != nil {
		resp.Diagnostics.AddAttributeError(
			req.Path,
			"Invalid RFC 3339 timestamp",
			fmt.Sprintf("value must be an RFC 3339 timestamp, for example 2026-06-24T11:00:00Z: %s", err.Error()),
		)
	}
}

// Runs the exact apply-time check the restore body builder uses (time.Parse RFC3339 after
// trimming), so plan and apply agree; a coarse regex passes 2026-13-24T.. that Parse rejects.
func RFC3339() validator.String {
	return rfc3339Validator{}
}
