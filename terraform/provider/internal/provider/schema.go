package provider

import (
	"context"
	"reflect"
	"regexp"
	"slices"

	"github.com/hashicorp/terraform-plugin-framework-timeouts/resource/timeouts"
	"github.com/hashicorp/terraform-plugin-framework-validators/int64validator"
	"github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator"
	dschema "github.com/hashicorp/terraform-plugin-framework/datasource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/identityschema"
	rschema "github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/booldefault"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/defaults"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/int64default"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringdefault"
	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
	"github.com/hashicorp/terraform-plugin-framework/types/basetypes"
)

func resourceSchema(ctx context.Context, t *typeDesc) rschema.Schema {
	return rschema.Schema{
		Description: t.doc,
		Attributes:  resourceAttrs(&t.objectDesc),
		Blocks: map[string]rschema.Block{
			"timeouts": timeouts.Block(ctx, timeouts.Opts{Create: true, Update: true, Delete: true}),
		},
	}
}

func resourceAttrs(o *objectDesc) map[string]rschema.Attribute {
	attrs := map[string]rschema.Attribute{}
	for _, a := range o.attrs {
		attrs[a.name] = resourceAttr(a)
	}
	return attrs
}

func resourceAttr(a *attrDesc) rschema.Attribute {
	r, o, c, s, d := a.has(required), a.has(optional), a.has(computed), a.has(sensitive), a.doc
	switch ty := a.ty.(type) {
	case *objectDesc:
		return rschema.SingleNestedAttribute{Attributes: resourceAttrs(ty), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.Object](a)}
	case collection:
		nested, isObject := ty.elem.(*objectDesc)
		switch {
		case isObject && ty.kind == "list":
			return rschema.ListNestedAttribute{NestedObject: rschema.NestedAttributeObject{Attributes: resourceAttrs(nested)}, Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.List](a)}
		case isObject && ty.kind == "set":
			return rschema.SetNestedAttribute{NestedObject: rschema.NestedAttributeObject{Attributes: resourceAttrs(nested)}, Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.Set](a)}
		case ty.kind == "list":
			return rschema.ListAttribute{ElementType: ty.elem.valueType(), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.List](a)}
		case ty.kind == "set":
			return rschema.SetAttribute{ElementType: ty.elem.valueType(), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.Set](a)}
		}
		return rschema.MapAttribute{ElementType: ty.elem.valueType(), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.Map](a)}
	}
	switch kindOf(a.ty) {
	case "int":
		return rschema.Int64Attribute{Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.Int64](a), Validators: int64Checks(a), Default: int64Default(a)}
	case "bool":
		return rschema.BoolAttribute{Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.Bool](a), Default: boolDefault(a)}
	}
	return rschema.StringAttribute{CustomType: a.ty.valueType().(basetypes.StringTypable), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d, PlanModifiers: rules[planmodifier.String](a), Validators: stringChecks(a), Default: stringDefault(a)}
}

// rules returns the plan modifiers an attribute's flags ask for, as M, the
// framework's interface for its kind. stable goes first, so that a computed
// input left unset keeps its value before replace compares it.
func rules[M any](a *attrDesc) (ms []M) {
	if a.has(stable) {
		ms = append(ms, any(keepState).(M))
	}
	if a.has(replace) && a.has(writeOnly) {
		ms = append(ms, any(replaceUnlessImported).(M))
	} else if a.has(replace) {
		ms = append(ms, any(requireReplace).(M))
	}
	return ms
}

func stringChecks(a *attrDesc) (vs []validator.String) {
	if a.pattern != "" {
		vs = append(vs, stringvalidator.RegexMatches(regexp.MustCompile(a.pattern), ""))
	}
	if a.lo != nil {
		vs = append(vs, stringvalidator.LengthAtLeast(int(*a.lo)))
	}
	if a.hi != nil {
		vs = append(vs, stringvalidator.LengthAtMost(int(*a.hi)))
	}
	if a.enum != nil {
		vs = append(vs, stringvalidator.OneOf(each(a.enum, func(v any) string { return v.(string) })...))
	}
	return vs
}

func int64Checks(a *attrDesc) (vs []validator.Int64) {
	if a.lo != nil {
		vs = append(vs, int64validator.AtLeast(*a.lo))
	}
	if a.hi != nil {
		vs = append(vs, int64validator.AtMost(*a.hi))
	}
	if a.enum != nil {
		vs = append(vs, int64validator.OneOf(each(a.enum, func(v any) int64 { return reflect.ValueOf(v).Int() })...))
	}
	return vs
}

func each[T any](vs []any, f func(any) T) []T {
	out := make([]T, len(vs))
	for i, v := range vs {
		out[i] = f(v)
	}
	return out
}

func stringDefault(a *attrDesc) defaults.String {
	if v, ok := a.def.(string); ok {
		return stringdefault.StaticString(v)
	}
	return nil
}

func int64Default(a *attrDesc) defaults.Int64 {
	if v, ok := a.def.(int64); ok {
		return int64default.StaticInt64(v)
	}
	return nil
}

func boolDefault(a *attrDesc) defaults.Bool {
	if v, ok := a.def.(bool); ok {
		return booldefault.StaticBool(v)
	}
	return nil
}

// datasourceSchema follows rule lookup: the item path's keys are required,
// exactly one lookup attribute is given, and every other attribute is
// computed. Write-only inputs, which the API never returns, are left out.
func datasourceSchema(t *typeDesc) dschema.Schema {
	ids := t.identity()
	keys := ids[:max(len(ids)-1, 0)]
	attrs := map[string]dschema.Attribute{}
	for _, a := range t.attrs {
		lookup := slices.Contains(t.lookup, a.name)
		switch {
		case a.has(writeOnly):
		case slices.Contains(keys, a.name):
			attrs[a.name] = datasourceAttr(a, true, false)
		default:
			attrs[a.name] = datasourceAttr(a, false, lookup)
		}
	}
	return dschema.Schema{Description: t.doc, Attributes: attrs}
}

// datasourceAttr builds a datasource attribute that is required, optional and
// computed, or only computed.
func datasourceAttr(a *attrDesc, r, o bool) dschema.Attribute {
	c, s, d := !r, a.has(sensitive), a.doc
	switch ty := a.ty.(type) {
	case *objectDesc:
		return dschema.SingleNestedAttribute{Attributes: computedAttrs(ty), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
	case collection:
		nested, isObject := ty.elem.(*objectDesc)
		switch {
		case isObject && ty.kind == "list":
			return dschema.ListNestedAttribute{NestedObject: dschema.NestedAttributeObject{Attributes: computedAttrs(nested)}, Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
		case isObject && ty.kind == "set":
			return dschema.SetNestedAttribute{NestedObject: dschema.NestedAttributeObject{Attributes: computedAttrs(nested)}, Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
		case ty.kind == "list":
			return dschema.ListAttribute{ElementType: ty.elem.valueType(), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
		case ty.kind == "set":
			return dschema.SetAttribute{ElementType: ty.elem.valueType(), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
		}
		return dschema.MapAttribute{ElementType: ty.elem.valueType(), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
	}
	switch kindOf(a.ty) {
	case "int":
		return dschema.Int64Attribute{Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
	case "bool":
		return dschema.BoolAttribute{Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
	}
	return dschema.StringAttribute{CustomType: a.ty.valueType().(basetypes.StringTypable), Required: r, Optional: o, Computed: c, Sensitive: s, Description: d}
}

func computedAttrs(o *objectDesc) map[string]dschema.Attribute {
	attrs := map[string]dschema.Attribute{}
	for _, a := range o.attrs {
		attrs[a.name] = datasourceAttr(a, false, false)
	}
	return attrs
}

// identitySchema follows rule import_id: the identity is made of the item
// path's attributes after project_id.
func identitySchema(t *typeDesc) identityschema.Schema {
	attrs := map[string]identityschema.Attribute{}
	for _, n := range t.identity() {
		attrs[n] = identityschema.StringAttribute{RequiredForImport: true, Description: t.find(n).doc}
	}
	return identityschema.Schema{Attributes: attrs}
}
