package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"slices"

	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

type values = map[string]tftypes.Value

func valuesOf(v tftypes.Value) values {
	var vals values
	_ = v.As(&vals)
	return vals
}

// decode converts JSON, decoded with UseNumber, to a value of ty. It ignores
// properties the descriptor does not name, so that an older provider keeps
// working against a newer API, and refuses anything else that does not fit,
// naming its JSON path.
func decode(ty attrType, raw any, at string) (tftypes.Value, error) {
	tt := ty.valueType().TerraformType(context.Background())
	if raw == nil {
		return tftypes.NewValue(tt, nil), nil
	}
	switch ty := ty.(type) {
	case *objectDesc:
		if m, ok := raw.(map[string]any); ok {
			vals := values{}
			for _, a := range ty.attrs {
				raw, _ := a.read(m)
				v, err := decode(a.ty, raw, at+"."+a.name)
				if err != nil {
					return v, err
				}
				vals[a.name] = v
			}
			return tftypes.NewValue(tt, vals), nil
		}
	case collection:
		if m, ok := raw.(map[string]any); ok && ty.kind == "map" {
			vals := values{}
			for k, e := range m {
				v, err := decode(ty.elem, e, fmt.Sprintf("%s[%q]", at, k))
				if err != nil {
					return v, err
				}
				vals[k] = v
			}
			return tftypes.NewValue(tt, vals), nil
		}
		if l, ok := raw.([]any); ok && ty.kind != "map" {
			vals := make([]tftypes.Value, len(l))
			for i, e := range l {
				v, err := decode(ty.elem, e, fmt.Sprintf("%s[%d]", at, i))
				if err != nil {
					return v, err
				}
				vals[i] = v
			}
			return tftypes.NewValue(tt, vals), nil
		}
	default:
		switch v := raw.(type) {
		case string:
			if kindOf(ty) == "string" {
				return tftypes.NewValue(tt, v), nil
			}
		case bool:
			if kindOf(ty) == "bool" {
				return tftypes.NewValue(tt, v), nil
			}
		case json.Number:
			f, _, err := big.ParseFloat(v.String(), 10, 512, big.ToNearestEven)
			if err == nil && kindOf(ty) == "int" && isInt64(f) {
				return tftypes.NewValue(tt, f), nil
			}
		}
	}
	got, _ := json.Marshal(raw)
	return tftypes.Value{}, fmt.Errorf("%s: expected %s, got %.80s", at, describe(ty), got)
}

func isInt64(f *big.Float) bool {
	_, acc := f.Int64()
	return acc == big.Exact
}

var kindNames = map[string]string{"string": "a string", "int": "an integer", "bool": "a boolean"}

func describe(ty attrType) string {
	if name, ok := kindNames[kindOf(ty)]; ok {
		return name
	}
	if c, ok := ty.(collection); ok && c.kind != "map" {
		return "an array"
	}
	return "an object"
}

// encode converts a known value of ty to JSON. Numbers stay exact, and an
// object leaves out null attributes that are not nullable.
func encode(ty attrType, v tftypes.Value) any {
	if v.IsNull() {
		return nil
	}
	switch ty := ty.(type) {
	case *objectDesc:
		var m values
		_ = v.As(&m)
		out := map[string]any{}
		for _, a := range ty.attrs {
			if e := m[a.name]; !e.IsNull() || a.has(nullable) {
				out[a.name] = encode(a.ty, e)
			}
		}
		return out
	case collection:
		if ty.kind == "map" {
			var m values
			_ = v.As(&m)
			out := map[string]any{}
			for k, e := range m {
				out[k] = encode(ty.elem, e)
			}
			return out
		}
		var l []tftypes.Value
		_ = v.As(&l)
		out := make([]any, len(l))
		for i, e := range l {
			out[i] = encode(ty.elem, e)
		}
		return out
	}
	switch kindOf(ty) {
	case "string":
		var s string
		_ = v.As(&s)
		return s
	case "bool":
		var b bool
		_ = v.As(&b)
		return b
	}
	var f big.Float
	_ = v.As(&f)
	return json.Number(f.Text('f', 0))
}

// body builds a request body from the planned values of names. An unknown
// planned value, as for a computed input the configuration leaves unset, is
// replaced by the prior value, or left out if that is not known either. A null
// is left out unless its attribute is nullable.
func (t *typeDesc) body(names []string, plan, prior values) map[string]any {
	out := map[string]any{}
	for _, n := range names {
		a, v := t.find(n), plan[n]
		if !v.IsFullyKnown() {
			var ok bool
			if v, ok = prior[n]; !ok || !v.IsFullyKnown() {
				continue
			}
		}
		if !v.IsNull() || a.has(nullable) {
			out[n] = encode(a.ty, v)
		}
	}
	return out
}

// state converts an item response to an object's values. Write-only inputs,
// which the API never returns, come from base, as do the timeouts block and
// any of the item path's attributes that the response leaves out.
func (t *typeDesc) state(body map[string]any, base values) (values, error) {
	if body == nil {
		return nil, errors.New("the response is empty")
	}
	out := values{}
	if v, ok := base["timeouts"]; ok {
		out["timeouts"] = v
	}
	keys := t.identity()
	for _, a := range t.attrs {
		raw, ok := a.read(body)
		if a.has(writeOnly) || !ok && slices.Contains(keys, a.name) {
			out[a.name] = base[a.name]
			continue
		}
		v, err := decode(a.ty, raw, a.name)
		if err != nil {
			return nil, err
		}
		out[a.name] = v
	}
	return out, nil
}

// read returns the attribute's value in a JSON object. An attribute declared
// with idsOf holds the id of the object, or of each object, in the property
// that it names.
func (a *attrDesc) read(m map[string]any) (any, bool) {
	if a.from == "" {
		raw, ok := m[a.name]
		return raw, ok
	}
	raw, ok := m[a.from]
	if l, isList := raw.([]any); isList {
		ids := make([]any, len(l))
		for i, e := range l {
			ids[i] = idOf(e)
		}
		return ids, ok
	}
	return idOf(raw), ok
}

// idOf returns an object's id, and anything else, including an object
// without an id, as it is, for decode to refuse.
func idOf(v any) any {
	if o, ok := v.(map[string]any); ok && o["id"] != nil {
		return o["id"]
	}
	return v
}

// known replaces the unknown values in vals, which state cannot hold, with
// nulls.
func known(vals values) values {
	out := values{}
	for k, v := range vals {
		out[k], _ = tftypes.Transform(v, func(_ *tftypes.AttributePath, v tftypes.Value) (tftypes.Value, error) {
			if !v.IsKnown() {
				return tftypes.NewValue(v.Type(), nil), nil
			}
			return v, nil
		})
	}
	return out
}
