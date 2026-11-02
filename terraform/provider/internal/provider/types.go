package provider

import (
	"cmp"
	"context"
	"fmt"
	"net/netip"
	"regexp"
	"strconv"

	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/attr/xattr"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-framework/types/basetypes"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

// formats holds, for each string format that the API rewrites, a function
// that canonicalizes a value as the API does. A value with no canonical form
// is not of the format.
var formats = map[string]func(string) (string, bool){
	"cidr":       canonicalCIDR,
	"port-range": canonicalPortRange,
}

// canonicalCIDR reads a bare address as a /32 or /128 network and masks the
// host bits, as Validation.validate_cidr does.
func canonicalCIDR(s string) (string, bool) {
	p, err := netip.ParsePrefix(s)
	if err != nil {
		a, err := netip.ParseAddr(s)
		if err != nil {
			return "", false
		}
		p = netip.PrefixFrom(a, a.BitLen())
	}
	return p.Masked().String(), true
}

var portRangePattern = regexp.MustCompile(`^(\d+)(?:\.\.(\d+))?$`)

// canonicalPortRange writes a..a as a, as the API does.
func canonicalPortRange(s string) (string, bool) {
	m := portRangePattern.FindStringSubmatch(s)
	if m == nil {
		return "", false
	}
	lo, err := strconv.Atoi(m[1])
	hi, err2 := strconv.Atoi(cmp.Or(m[2], m[1]))
	if err != nil || err2 != nil || lo > hi || hi > 65535 {
		return "", false
	}
	if lo == hi {
		return strconv.Itoa(lo), true
	}
	return fmt.Sprintf("%d..%d", lo, hi), true
}

// formatType is the string type of a format in formats. Two of its values are
// equal when their canonical forms are, so that a plan keeps what the user
// wrote. A value that is not of the format is refused at plan time.
type formatType struct {
	basetypes.StringType
	format string
}

type formatValue struct {
	basetypes.StringValue
	format string
}

var (
	_ basetypes.StringTypable                    = formatType{}
	_ basetypes.StringValuableWithSemanticEquals = formatValue{}
	_ xattr.ValidateableAttribute                = formatValue{}
)

func (t formatType) String() string { return "formatType(" + t.format + ")" }

func (t formatType) Equal(o attr.Type) bool {
	other, ok := o.(formatType)
	return ok && other.format == t.format
}

func (t formatType) ValueType(context.Context) attr.Value { return formatValue{format: t.format} }

func (t formatType) ValueFromString(_ context.Context, v basetypes.StringValue) (basetypes.StringValuable, diag.Diagnostics) {
	return formatValue{v, t.format}, nil
}

func (t formatType) ValueFromTerraform(ctx context.Context, in tftypes.Value) (attr.Value, error) {
	v, err := t.StringType.ValueFromTerraform(ctx, in)
	if err != nil {
		return nil, err
	}
	return formatValue{v.(basetypes.StringValue), t.format}, nil
}

func (v formatValue) Type(context.Context) attr.Type { return formatType{format: v.format} }

func (v formatValue) Equal(o attr.Value) bool {
	other, ok := o.(formatValue)
	return ok && other.format == v.format && other.StringValue.Equal(v.StringValue)
}

func (v formatValue) StringSemanticEquals(_ context.Context, o basetypes.StringValuable) (bool, diag.Diagnostics) {
	other, ok := o.(formatValue)
	if !ok {
		return false, nil
	}
	a, okA := formats[v.format](v.ValueString())
	b, okB := formats[v.format](other.ValueString())
	return okA && okB && a == b, nil
}

func (v formatValue) ValidateAttribute(_ context.Context, req xattr.ValidateAttributeRequest, resp *xattr.ValidateAttributeResponse) {
	if v.IsNull() || v.IsUnknown() {
		return
	}
	if _, ok := formats[v.format](v.ValueString()); !ok {
		resp.Diagnostics.AddAttributeError(req.Path, "Invalid "+v.format, fmt.Sprintf("%q is not a valid %s.", v.ValueString(), v.format))
	}
}

// A planRule is a plan modifier that schema.go derives from flags, written
// once for attributes of every kind.
type planRule int

const (
	keepState planRule = iota
	requireReplace
	replaceUnlessImported
)

// importedKey is the private state key that ImportState writes and Update
// clears.
const importedKey = "imported"

var planRuleText = map[planRule]string{
	keepState:             "Keeps the value in state when the plan does not know it.",
	requireReplace:        "Changing the value replaces the resource.",
	replaceUnlessImported: "Changing the value replaces the resource, except that the first value after an import is adopted.",
}

func (r planRule) Description(context.Context) string             { return planRuleText[r] }
func (r planRule) MarkdownDescription(ctx context.Context) string { return r.Description(ctx) }

// privateData is the framework's private state, whose type is internal.
type privateData interface {
	GetKey(context.Context, string) ([]byte, diag.Diagnostics)
}

// modifyPlan applies rule r to one attribute's planned value and reports
// whether the change replaces the resource. replaceUnlessImported adopts a
// value without replacing while the private state carries the import marker
// and the prior value is null, because the API never returns a write-only
// input and an import therefore leaves it null.
func modifyPlan[V attr.Value](ctx context.Context, r planRule, state tfsdk.State, plan tfsdk.Plan, private privateData, config, prior, planned V) (V, bool) {
	if state.Raw.IsNull() || plan.Raw.IsNull() {
		return planned, false
	}
	switch {
	case r == keepState && planned.IsUnknown() && !config.IsUnknown():
		return prior, false
	case r == keepState || planned.Equal(prior):
		return planned, false
	case r == replaceUnlessImported && prior.IsNull():
		marker, _ := private.GetKey(ctx, importedKey)
		return planned, marker == nil
	}
	return planned, true
}

func (r planRule) PlanModifyString(ctx context.Context, req planmodifier.StringRequest, resp *planmodifier.StringResponse) {
	resp.PlanValue, resp.RequiresReplace = modifyPlan(ctx, r, req.State, req.Plan, req.Private, req.ConfigValue, req.StateValue, req.PlanValue)
}

func (r planRule) PlanModifyInt64(ctx context.Context, req planmodifier.Int64Request, resp *planmodifier.Int64Response) {
	resp.PlanValue, resp.RequiresReplace = modifyPlan(ctx, r, req.State, req.Plan, req.Private, req.ConfigValue, req.StateValue, req.PlanValue)
}

func (r planRule) PlanModifyBool(ctx context.Context, req planmodifier.BoolRequest, resp *planmodifier.BoolResponse) {
	resp.PlanValue, resp.RequiresReplace = modifyPlan(ctx, r, req.State, req.Plan, req.Private, req.ConfigValue, req.StateValue, req.PlanValue)
}

func (r planRule) PlanModifyList(ctx context.Context, req planmodifier.ListRequest, resp *planmodifier.ListResponse) {
	resp.PlanValue, resp.RequiresReplace = modifyPlan(ctx, r, req.State, req.Plan, req.Private, req.ConfigValue, req.StateValue, req.PlanValue)
}

func (r planRule) PlanModifySet(ctx context.Context, req planmodifier.SetRequest, resp *planmodifier.SetResponse) {
	resp.PlanValue, resp.RequiresReplace = modifyPlan(ctx, r, req.State, req.Plan, req.Private, req.ConfigValue, req.StateValue, req.PlanValue)
}

func (r planRule) PlanModifyMap(ctx context.Context, req planmodifier.MapRequest, resp *planmodifier.MapResponse) {
	resp.PlanValue, resp.RequiresReplace = modifyPlan(ctx, r, req.State, req.Plan, req.Private, req.ConfigValue, req.StateValue, req.PlanValue)
}

func (r planRule) PlanModifyObject(ctx context.Context, req planmodifier.ObjectRequest, resp *planmodifier.ObjectResponse) {
	resp.PlanValue, resp.RequiresReplace = modifyPlan(ctx, r, req.State, req.Plan, req.Private, req.ConfigValue, req.StateValue, req.PlanValue)
}
