package provider

import (
	"context"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/attr/xattr"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-framework/types/basetypes"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

func TestFormats(t *testing.T) {
	for in, want := range map[string]string{
		"10.0.0.5/8":     "10.0.0.0/8",
		"10.0.0.5":       "10.0.0.5/32",
		"2001:db8::5":    "2001:db8::5/128",
		"2001:db8::5/64": "2001:db8::/64",
		"fw0123456789":   "",
		"10.0.0.0/33":    "",
	} {
		if got, ok := canonicalCIDR(in); got != want || ok != (want != "") {
			t.Errorf("canonicalCIDR(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
	for in, want := range map[string]string{
		"22..22":   "22",
		"0..65535": "0..65535",
		"080":      "80",
		"23..22":   "",
		"65536":    "",
		"1..2..3":  "",
		"http":     "",
	} {
		if got, ok := canonicalPortRange(in); got != want || ok != (want != "") {
			t.Errorf("canonicalPortRange(%q) = %q, %v; want %q", in, got, ok, want)
		}
	}
}

func TestFormatValue(t *testing.T) {
	ctx := context.Background()
	value := func(s string) formatValue {
		v, _ := formatType{format: "cidr"}.ValueFromString(ctx, types.StringValue(s))
		return v.(formatValue)
	}
	for _, tt := range []struct {
		a, b string
		want bool
	}{{"10.0.0.5/8", "10.0.0.0/8", true}, {"10.0.0.5", "10.0.0.5/32", true}, {"10.0.0.0/8", "10.0.0.0/16", false}, {"bad", "bad", false}} {
		if got, _ := value(tt.a).StringSemanticEquals(ctx, value(tt.b)); got != tt.want {
			t.Errorf("%s equals %s: %v", tt.a, tt.b, got)
		}
	}
	var resp xattr.ValidateAttributeResponse
	value("web-tier").ValidateAttribute(ctx, xattr.ValidateAttributeRequest{Path: path.Root("cidr")}, &resp)
	if !resp.Diagnostics.HasError() || resp.Diagnostics[0].Summary() != "Invalid cidr" {
		t.Errorf("web-tier passed validation: %v", resp.Diagnostics)
	}
	resp = xattr.ValidateAttributeResponse{}
	formatValue{types.StringNull(), "cidr"}.ValidateAttribute(ctx, xattr.ValidateAttributeRequest{Path: path.Root("cidr")}, &resp)
	if resp.Diagnostics.HasError() {
		t.Errorf("a null failed validation: %v", resp.Diagnostics)
	}
	if eq, _ := value("10.0.0.0/8").StringSemanticEquals(ctx, types.StringValue("10.0.0.0/8")); eq {
		t.Errorf("a plain string equals a cidr")
	}
	ty := formatType{format: "cidr"}
	v, err := ty.ValueFromTerraform(ctx, tfStr("10.0.0.0/8"))
	if !v.Equal(value("10.0.0.0/8")) || err != nil {
		t.Errorf("ValueFromTerraform = %v, %v", v, err)
	}
	if _, err := ty.ValueFromTerraform(ctx, tftypes.NewValue(tftypes.Number, 1)); err == nil {
		t.Errorf("ValueFromTerraform took a number")
	}
	if ty.String() != "formatType(cidr)" || !ty.Equal(stringOf("cidr").valueType()) || ty.Equal(formatType{format: "port-range"}) ||
		ty.Equal(types.StringType) || !ty.ValueType(ctx).Type(ctx).Equal(ty) {
		t.Errorf("formatType %v does not describe itself", ty)
	}
}

func TestPlanRules(t *testing.T) {
	ctx := context.Background()
	exists := tftypes.NewValue(tftypes.Object{}, map[string]tftypes.Value{})
	imported := newHarness(t, gadget(), nil).importState("l1/g1").Private
	fresh := imported
	newPrivate(&fresh)
	null, unknown, a, b := types.StringNull(), types.StringUnknown(), types.StringValue("a"), types.StringValue("b")
	tests := []struct {
		name             string
		rule             planRule
		creating, marked bool
		prior, planned   basetypes.StringValue
		wantPlan         basetypes.StringValue
		wantReplace      bool
	}{
		{"stable keeps an unknown's prior value", keepState, false, false, a, unknown, a, false},
		{"stable keeps a planned value", keepState, false, false, a, b, b, false},
		{"replace on change", requireReplace, false, false, a, b, b, true},
		{"no replace without change", requireReplace, false, false, a, a, a, false},
		{"no replace on create", requireReplace, true, false, null, b, b, false},
		{"adopt after import", replaceUnlessImported, false, true, null, b, b, false},
		{"replace a value first set after create", replaceUnlessImported, false, false, null, b, b, true},
		{"replace a change after import", replaceUnlessImported, false, true, a, b, b, true},
	}
	for _, tt := range tests {
		state, private := tfsdk.State{Raw: exists}, fresh
		if tt.creating {
			state.Raw = tftypes.NewValue(tftypes.Object{}, nil)
		}
		if tt.marked {
			private = imported
		}
		var resp planmodifier.StringResponse
		tt.rule.PlanModifyString(ctx, planmodifier.StringRequest{State: state, Plan: tfsdk.Plan{Raw: exists}, Private: private,
			StateValue: tt.prior, PlanValue: tt.planned, ConfigValue: null}, &resp)
		if !resp.PlanValue.Equal(tt.wantPlan) || resp.RequiresReplace != tt.wantReplace {
			t.Errorf("%s: plan %v, replace %v", tt.name, resp.PlanValue, resp.RequiresReplace)
		}
	}
	if !strings.Contains(replaceUnlessImported.MarkdownDescription(ctx), "import") {
		t.Errorf("description %q", replaceUnlessImported.MarkdownDescription(ctx))
	}

	// Every kind's method applies the same rule: a change replaces.
	plan := tfsdk.Plan{Raw: exists}
	exist := tfsdk.State{Raw: exists}
	noAttrs := map[string]attr.Type{}
	for kind, replaces := range map[string]func() bool{
		"int64": func() bool {
			var resp planmodifier.Int64Response
			requireReplace.PlanModifyInt64(ctx, planmodifier.Int64Request{State: exist, Plan: plan, StateValue: types.Int64Null(), PlanValue: types.Int64Value(1)}, &resp)
			return resp.RequiresReplace
		},
		"bool": func() bool {
			var resp planmodifier.BoolResponse
			requireReplace.PlanModifyBool(ctx, planmodifier.BoolRequest{State: exist, Plan: plan, StateValue: types.BoolNull(), PlanValue: types.BoolValue(true)}, &resp)
			return resp.RequiresReplace
		},
		"list": func() bool {
			var resp planmodifier.ListResponse
			requireReplace.PlanModifyList(ctx, planmodifier.ListRequest{State: exist, Plan: plan, StateValue: types.ListNull(types.StringType), PlanValue: types.ListValueMust(types.StringType, nil)}, &resp)
			return resp.RequiresReplace
		},
		"set": func() bool {
			var resp planmodifier.SetResponse
			requireReplace.PlanModifySet(ctx, planmodifier.SetRequest{State: exist, Plan: plan, StateValue: types.SetNull(types.StringType), PlanValue: types.SetValueMust(types.StringType, nil)}, &resp)
			return resp.RequiresReplace
		},
		"map": func() bool {
			var resp planmodifier.MapResponse
			requireReplace.PlanModifyMap(ctx, planmodifier.MapRequest{State: exist, Plan: plan, StateValue: types.MapNull(types.StringType), PlanValue: types.MapValueMust(types.StringType, nil)}, &resp)
			return resp.RequiresReplace
		},
		"object": func() bool {
			var resp planmodifier.ObjectResponse
			requireReplace.PlanModifyObject(ctx, planmodifier.ObjectRequest{State: exist, Plan: plan, StateValue: types.ObjectNull(noAttrs), PlanValue: types.ObjectValueMust(noAttrs, nil)}, &resp)
			return resp.RequiresReplace
		},
	} {
		if !replaces() {
			t.Errorf("%s: a change does not replace", kind)
		}
	}
}
