package provider

import (
	"context"
	"slices"
	"strings"
	"testing"
)

// checkType runs validate and the framework's checks of the schemas built
// from a descriptor.
func checkType(t *testing.T, ty *typeDesc) {
	t.Helper()
	ctx := context.Background()
	if err := ty.validate(); err != nil {
		t.Error(err)
	}
	diags := resourceSchema(ctx, ty).ValidateImplementation(ctx)
	diags.Append(datasourceSchema(ty).ValidateImplementation(ctx)...)
	diags.Append(identitySchema(ty).ValidateImplementation(ctx)...)
	for _, d := range diags {
		t.Errorf("%s: %s: %s", ty.name, d.Summary(), d.Detail())
	}
}

func TestRegisteredTypes(t *testing.T) {
	for _, ty := range append([]*typeDesc{gadget(), part(), scope(), everything()}, registry...) {
		checkType(t, ty)
	}
}

func TestValidate(t *testing.T) {
	ty := newType("broken", "/{project_id}/broken/{slug}", "Broken")
	ty.create("POST", "/{project_id}/broken/{name}", "size", "colour")
	ty.datasource("id", "nickname")
	ty.pending("phase", "starting")
	ty.verb("PATCH", "", "size")
	ty.attr("size", i64, optional, "Size")
	err := ty.validate()
	for _, want := range []string{
		"broken: item path /{project_id}/broken/{slug} does not end in {id}",
		"broken: GET /{project_id}/broken/{slug}: {slug} is not an attribute",
		"broken: POST /{project_id}/broken/{name}: {name} is not an attribute",
		"broken: POST /{project_id}/broken/{name}: body names colour, which is not an attribute",
		"broken: phase is not an attribute",
		"broken: id is not an attribute",
		"broken: nickname is not an attribute",
	} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("validate() = %v\nwant %q", err, want)
		}
	}
}

func TestOwned(t *testing.T) {
	ty := newType("x", "/x/{id}", "X")
	ty.verb("POST", "/upgrade", "version")
	ty.verb("PATCH", "", "size", "version")
	ty.verb("POST", "/rename", "name", "size")
	for i, want := range [][]string{{"version"}, {"size"}, {"name"}} {
		if got := ty.owned(i); !slices.Equal(got, want) {
			t.Errorf("owned(%d) = %v, want %v", i, got, want)
		}
	}
}
