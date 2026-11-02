package provider

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework-timetypes/timetypes"
	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/types"
	"github.com/hashicorp/terraform-plugin-framework/types/basetypes"
)

// Each generated file describes one terraform type with the builder calls
// below and registers it from init. The descriptors hold no control flow; the
// engine reads from them everything it needs to know about a type.

// A typeDesc describes one terraform type. In its paths, {project_id} comes
// from the provider and every other placeholder names an attribute. The item
// path's last placeholder identifies the object, and for a resource it is
// {id}.
type typeDesc struct {
	objectDesc
	name, item, doc string
	createOp        *operation
	verbs           []operation
	lookup          []string
	life            lifecycle
}

// An operation is a request and the attributes its body carries. A create's
// path is absolute; a verb's is relative to the item path.
type operation struct {
	method, path string
	body         []string
}

// A lifecycle names the attribute that x-lifecycle marks, and the values in
// which the object is still pending and those in which it has failed.
type lifecycle struct {
	attr            string
	pending, failed []string
}

// An objectDesc holds the attributes of a type or of a nested object.
type objectDesc struct {
	attrs []*attrDesc
}

type attrDesc struct {
	name    string
	ty      attrType
	flags   flag
	doc     string
	pattern string
	enum    []any
	// lo and hi bound an integer, or the length of a string.
	lo, hi *int64
	def    any
	// from names the response property that holds the objects whose ids
	// the attribute holds.
	from string
}

// An attrType is a scalar, a list, set or map of an element type, or a nested
// object.
type attrType interface {
	valueType() attr.Type
}

type scalar struct{ t attr.Type }

type collection struct {
	kind string
	elem attrType
}

type flag uint

const (
	required flag = 1 << iota
	optional
	computed
	sensitive
	replace
	stable
	writeOnly
	nullable
)

var (
	str       attrType = scalar{types.StringType}
	i64       attrType = scalar{types.Int64Type}
	boolean   attrType = scalar{types.BoolType}
	timestamp attrType = scalar{timetypes.RFC3339Type{}}
)

func stringOf(format string) attrType { return scalar{formatType{format: format}} }
func listOf(elem attrType) attrType   { return collection{"list", elem} }
func setOf(elem attrType) attrType    { return collection{"set", elem} }
func mapOf(elem attrType) attrType    { return collection{"map", elem} }
func single(o *objectDesc) attrType   { return o }

// An option adds a check or a default to an attribute, or names the property
// it is read from.
type option func(*attrDesc)

func matches(pattern string) option { return func(a *attrDesc) { a.pattern = pattern } }
func oneOf(values ...any) option    { return func(a *attrDesc) { a.enum = values } }
func atLeast(lo int64) option       { return func(a *attrDesc) { a.lo = &lo } }
func atMost(hi int64) option        { return func(a *attrDesc) { a.hi = &hi } }
func defaultString(v string) option { return func(a *attrDesc) { a.def = v } }
func defaultInt(v int64) option     { return func(a *attrDesc) { a.def = v } }
func defaultBool(v bool) option     { return func(a *attrDesc) { a.def = v } }
func idsOf(property string) option  { return func(a *attrDesc) { a.from = property } }

func newType(name, item, doc string) *typeDesc {
	return &typeDesc{name: name, item: item, doc: doc}
}

func (t *typeDesc) create(method, path string, body ...string) {
	t.createOp = &operation{method, path, body}
}

func (t *typeDesc) datasource(lookup ...string) { t.lookup = lookup }

func (t *typeDesc) pending(attr string, values ...string) { t.life.attr, t.life.pending = attr, values }

func (t *typeDesc) failed(attr string, values ...string) { t.life.attr, t.life.failed = attr, values }

func (t *typeDesc) verb(method, path string, body ...string) {
	t.verbs = append(t.verbs, operation{method, path, body})
}

func object() *objectDesc { return &objectDesc{} }

func (o *objectDesc) attr(name string, ty attrType, f flag, doc string, opts ...option) {
	a := &attrDesc{name: name, ty: ty, flags: f, doc: doc}
	for _, opt := range opts {
		opt(a)
	}
	o.attrs = append(o.attrs, a)
}

var registry []*typeDesc

func register(t *typeDesc) { registry = append(registry, t) }

func (s scalar) valueType() attr.Type { return s.t }

func (c collection) valueType() attr.Type {
	switch c.kind {
	case "list":
		return types.ListType{ElemType: c.elem.valueType()}
	case "set":
		return types.SetType{ElemType: c.elem.valueType()}
	}
	return types.MapType{ElemType: c.elem.valueType()}
}

func (o *objectDesc) valueType() attr.Type {
	ts := map[string]attr.Type{}
	for _, a := range o.attrs {
		ts[a.name] = a.ty.valueType()
	}
	return types.ObjectType{AttrTypes: ts}
}

func (o *objectDesc) find(name string) *attrDesc {
	i := slices.IndexFunc(o.attrs, func(a *attrDesc) bool { return a.name == name })
	if i < 0 {
		return nil
	}
	return o.attrs[i]
}

func (a *attrDesc) has(f flag) bool { return a.flags&f != 0 }

// kindOf names the value kind of a scalar type, which decides its checks,
// default and JSON form, and returns "" for any other type.
func kindOf(ty attrType) string {
	s, ok := ty.(scalar)
	if !ok {
		return ""
	}
	switch s.t.(type) {
	case basetypes.StringTypable:
		return "string"
	case basetypes.Int64Typable:
		return "int"
	}
	return "bool"
}

var placeholderPattern = regexp.MustCompile(`\{(\w+)\}`)

func placeholders(path string) (names []string) {
	for _, m := range placeholderPattern.FindAllStringSubmatch(path, -1) {
		names = append(names, m[1])
	}
	return names
}

func (t *typeDesc) typeName() string { return "ubicloud_" + t.name }

// identity returns the item path's attributes after the provider's
// project_id. They are the parts of an import ID, in order, and the
// attributes of the resource identity.
func (t *typeDesc) identity() []string {
	return slices.DeleteFunc(placeholders(t.item), func(n string) bool { return n == "project_id" })
}

// named reports whether the type can be looked up by name. The name is then
// the create's idempotency key.
func (t *typeDesc) named() bool { return slices.Contains(t.lookup, "name") }

// owned returns the attributes that verb i owns: those in its body that no
// earlier verb carries.
func (t *typeDesc) owned(i int) []string {
	return slices.DeleteFunc(slices.Clone(t.verbs[i].body), func(n string) bool {
		return slices.IndexFunc(t.verbs, func(v operation) bool { return slices.Contains(v.body, n) }) != i
	})
}

// validate checks a descriptor for what the compiler cannot: that every name
// its operations, datasource and lifecycle use is one of its attributes, and
// that a resource's item path ends in {id}.
func (t *typeDesc) validate() error {
	var errs []error
	fail := func(format string, args ...any) {
		errs = append(errs, fmt.Errorf(t.name+": "+format, args...))
	}
	ops := append([]operation{{method: "GET", path: t.item}}, t.verbs...)
	if t.createOp != nil {
		ops = append(ops, *t.createOp)
		if !strings.HasSuffix(t.item, "/{id}") {
			fail("item path %s does not end in {id}", t.item)
		}
	}
	for _, op := range ops {
		for _, n := range placeholders(op.path) {
			if n != "project_id" && t.find(n) == nil {
				fail("%s %s: {%s} is not an attribute", op.method, op.path, n)
			}
		}
		for _, n := range op.body {
			if t.find(n) == nil {
				fail("%s %s: body names %s, which is not an attribute", op.method, op.path, n)
			}
		}
	}
	for _, n := range append([]string{t.life.attr}, t.lookup...) {
		if n != "" && t.find(n) == nil {
			fail("%s is not an attribute", n)
		}
	}
	return errors.Join(errs...)
}
