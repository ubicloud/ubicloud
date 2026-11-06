package validators

import (
	"context"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
)

type notBlankValidator struct{}

func (notBlankValidator) Description(_ context.Context) string {
	return "value must not be blank"
}

func (v notBlankValidator) MarkdownDescription(ctx context.Context) string {
	return v.Description(ctx)
}

func (notBlankValidator) ValidateString(_ context.Context, req validator.StringRequest, resp *validator.StringResponse) {
	if req.ConfigValue.IsNull() || req.ConfigValue.IsUnknown() {
		return
	}
	if strings.TrimSpace(req.ConfigValue.ValueString()) == "" {
		resp.Diagnostics.AddAttributeError(
			req.Path,
			"Blank parent",
			"parent cannot be blank; omit it to create a primary database or keep the current one, or set it to the source database to restore from or replicate. This provider cannot clear parent to promote a read replica. A blank value fails config validation on every operation, including a terraform destroy that -refresh=false does not skip.",
		)
	}
}

// NotBlank rejects a KNOWN present-but-blank string (whitespace trims to empty); null and unknown
// skip, so an omitted parent stays a primary and an interpolated one defers to Create's apply-time
// backstop. As config validation it rejects a blank on every operation, including a terraform
// destroy that -refresh=false does not skip. The message is tailored to parent, its only consumer.
func NotBlank() validator.String {
	return notBlankValidator{}
}
