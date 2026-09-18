package validators

import (
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

// RFC3339() must accept exactly what time.Parse(time.RFC3339) accepts after a trim, so plan-time
// validation and the apply-time restore body agree; null/unknown skip (unknowns parse at apply).
func TestRFC3339(t *testing.T) {
	cases := []struct {
		name    string
		val     types.String
		wantErr bool
	}{
		{"null skipped", types.StringNull(), false},
		{"unknown skipped", types.StringUnknown(), false},
		{"valid Z", types.StringValue("2026-06-24T11:00:00Z"), false},
		{"valid offset", types.StringValue("2026-06-24T11:00:00+02:00"), false},
		{"valid fractional", types.StringValue("2026-06-24T11:00:00.5Z"), false},
		{"valid trimmed", types.StringValue("  2026-06-24T11:00:00Z  "), false},
		{"empty rejected", types.StringValue(""), true},
		{"whitespace rejected", types.StringValue("   "), true},
		{"garbage rejected", types.StringValue("not-a-timestamp"), true},
		{"date only rejected", types.StringValue("2026-06-24"), true},
		{"month 13 rejected", types.StringValue("2026-13-24T11:00:00Z"), true},
		{"hour 24 rejected", types.StringValue("2026-06-24T24:00:00Z"), true},
		{"second 60 rejected", types.StringValue("2026-06-24T11:00:60Z"), true},
	}
	for _, c := range cases {
		req := validator.StringRequest{Path: path.Root("restore_target"), ConfigValue: c.val}
		resp := &validator.StringResponse{}
		RFC3339().ValidateString(t.Context(), req, resp)
		if got := resp.Diagnostics.HasError(); got != c.wantErr {
			t.Errorf("%s: HasError = %v, want %v (diags: %+v)", c.name, got, c.wantErr, resp.Diagnostics)
		}
	}
}
