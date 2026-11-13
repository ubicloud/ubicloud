package validators

import (
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

// NotBlank() must reject a KNOWN present-but-blank value while skipping null and unknown, so an
// omitted parent stays a primary and an interpolated one defers to the apply-time backstop.
func TestNotBlank(t *testing.T) {
	cases := []struct {
		name    string
		val     types.String
		wantErr bool
	}{
		{"null skipped", types.StringNull(), false},
		{"unknown skipped", types.StringUnknown(), false},
		{"name accepted", types.StringValue("tf-acc-src"), false},
		{"padded name accepted", types.StringValue("  tf-acc-src  "), false},
		{"empty rejected", types.StringValue(""), true},
		{"whitespace rejected", types.StringValue("   "), true},
		{"tab and newline rejected", types.StringValue("\t\n"), true},
	}
	for _, c := range cases {
		req := validator.StringRequest{Path: path.Root("parent"), ConfigValue: c.val}
		resp := &validator.StringResponse{}
		NotBlank().ValidateString(t.Context(), req, resp)
		if got := resp.Diagnostics.HasError(); got != c.wantErr {
			t.Errorf("%s: HasError = %v, want %v (diags: %+v)", c.name, got, c.wantErr, resp.Diagnostics)
		}
	}
}

// The rejection must carry the "Blank parent" summary the provider UX and the plan tests key on,
// name the valid alternatives so the user story survives the message merge, and (because config
// validation blocks a destroy that -refresh=false cannot skip) tell the user so.
func TestNotBlankMessage(t *testing.T) {
	req := validator.StringRequest{Path: path.Root("parent"), ConfigValue: types.StringValue("")}
	resp := &validator.StringResponse{}
	NotBlank().ValidateString(t.Context(), req, resp)
	errs := resp.Diagnostics.Errors()
	if len(errs) != 1 || errs[0].Summary() != "Blank parent" {
		t.Fatalf("want exactly one \"Blank parent\" error, got %+v", resp.Diagnostics)
	}
	detail := errs[0].Detail()
	if !strings.Contains(detail, "omit it") {
		t.Errorf("detail must advise omitting parent, got %q", detail)
	}
	if !strings.Contains(detail, "terraform destroy") {
		t.Errorf("detail must warn that a blank parent also blocks a destroy, got %q", detail)
	}
}
