package provider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hashicorp/terraform-plugin-log/tflog"
)

type client struct {
	endpoint  string
	token     string
	projectID string
	userAgent string
	poll      time.Duration
	http      *http.Client
}

type request struct {
	method, path string
	body         map[string]any
	// once marks a create, which is not repeated if the server may have
	// seen it.
	once bool
}

type apiError struct {
	method, path string
	status       int
	kind         string
	message      string
	details      map[string]any
}

func (e *apiError) Error() string {
	s := fmt.Sprintf("%s %s: %d %s", e.method, e.path, e.status, e.kind)
	if e.message != "" {
		s += ": " + e.message
	}
	return s
}

// ambiguousError is the failure of a create that may have taken effect,
// although no usable answer came back.
type ambiguousError struct{ err error }

func (e *ambiguousError) Error() string { return e.err.Error() }
func (e *ambiguousError) Unwrap() error { return e.err }

func isNotFound(err error) bool {
	var e *apiError
	return errors.As(err, &e) && e.status == http.StatusNotFound
}

// taken reports whether err is the refusal of a create whose name is taken.
// The API reports that as a 400 whose details are keyed by name.
func taken(err error) bool {
	var e *apiError
	return errors.As(err, &e) && e.status == http.StatusBadRequest && e.details["name"] != nil
}

// fill fills a path's placeholders: {project_id} from the provider, and every
// other one from vals.
func (c *client) fill(path string, vals values) (string, error) {
	var err error
	out := placeholderPattern.ReplaceAllStringFunc(path, func(m string) string {
		name := m[1 : len(m)-1]
		if name == "project_id" {
			return url.PathEscape(c.projectID)
		}
		var s string
		if vals[name].As(&s) != nil || s == "" {
			err = fmt.Errorf("{%s} in %s has no value", name, path)
		}
		return url.PathEscape(s)
	})
	return out, err
}

type attempt struct {
	status int
	header http.Header
	body   []byte
	err    error
	// sent reports whether the whole request was written, in which case
	// the server may have acted on it.
	sent bool
}

func (c *client) send(ctx context.Context, req request, payload []byte) attempt {
	var sent atomic.Bool
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		WroteRequest: func(i httptrace.WroteRequestInfo) { sent.Store(i.Err == nil) },
	})
	hr, err := http.NewRequestWithContext(ctx, req.method, c.endpoint+req.path, bytes.NewReader(payload))
	if err != nil {
		return attempt{err: err}
	}
	hr.Header.Set("Authorization", "Bearer "+c.token)
	hr.Header.Set("User-Agent", c.userAgent)
	hr.Header.Set("Accept", "application/vnd.ubicloud+json; version=2")
	if payload != nil {
		hr.Header.Set("Content-Type", "application/json")
	}
	res, err := c.http.Do(hr)
	if err != nil {
		return attempt{err: err, sent: sent.Load()}
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	return attempt{status: res.StatusCode, header: res.Header, body: body, err: err, sent: true}
}

// do sends a request, following rule retry. A refusal (a 429, or any error
// answer with Retry-After) has changed nothing, so the request is repeated
// after the longer of the header's delay and the poll interval, until ctx's
// deadline. After a 502, 503 or 504, or a transport error, it is repeated
// after the poll interval, giving up after five such failures in a row. But
// if req.once is set and the server may have seen the request, such a
// failure, or a 2xx whose body does not decode, is returned as an
// ambiguousError instead. Any other failure is returned at once; in
// particular a 500, which means a bug in the API, is not repeated.
func (c *client) do(ctx context.Context, req request) (map[string]any, error) {
	var payload []byte
	if req.body != nil {
		payload, _ = json.Marshal(req.body)
	}
	for failures := 0; ; {
		a := c.send(ctx, req, payload)
		tflog.Debug(ctx, "API request", map[string]any{"method": req.method, "path": req.path, "status": a.status})
		err := a.err
		if err == nil && a.status/100 == 2 {
			var obj map[string]any
			if obj, err = decodeObject(a.body); err == nil {
				return obj, nil
			}
		} else if err == nil {
			err = newAPIError(req, a)
		}
		retryable := a.err != nil || req.once && a.status/100 == 2 || a.status == http.StatusBadGateway ||
			a.status == http.StatusServiceUnavailable || a.status == http.StatusGatewayTimeout
		wait, refused := retryAfter(a)
		switch {
		case refused:
			failures = 0
		case !retryable:
			return nil, err
		case req.once && a.sent:
			return nil, &ambiguousError{err}
		case ctx.Err() != nil:
			return nil, err
		default:
			if failures++; failures == 5 {
				return nil, fmt.Errorf("%w (after %d attempts)", err, failures)
			}
		}
		if serr := sleep(ctx, max(wait, c.poll)); serr != nil {
			return nil, fmt.Errorf("%w; the last answer was %w", serr, err)
		}
	}
}

// id sends req and returns the id of the object the answer describes. An
// answer without one leaves a create's outcome unknown, as a lost answer
// does.
func (c *client) id(ctx context.Context, req request) (string, error) {
	body, err := c.do(ctx, req)
	if err != nil {
		return "", err
	}
	if id, _ := body["id"].(string); id != "" {
		return id, nil
	}
	return "", &ambiguousError{fmt.Errorf("%s %s: the response has no id", req.method, req.path)}
}

func decodeObject(b []byte) (map[string]any, error) {
	if len(bytes.TrimSpace(b)) == 0 {
		return nil, nil
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var obj map[string]any
	if err := dec.Decode(&obj); err != nil {
		return nil, fmt.Errorf("the response body does not decode: %w", err)
	}
	return obj, nil
}

// retryAfter reports whether an answer refuses the request for now, and how
// long the API asked to wait.
func retryAfter(a attempt) (time.Duration, bool) {
	if a.err != nil || a.status < 400 {
		return 0, false
	}
	h := a.header.Get("Retry-After")
	if h == "" {
		return 0, a.status == http.StatusTooManyRequests
	}
	s, _ := strconv.Atoi(h)
	return time.Duration(s) * time.Second, true
}

func newAPIError(req request, a attempt) *apiError {
	e := &apiError{method: req.method, path: req.path, status: a.status}
	var body struct {
		Error struct {
			Type    string
			Message string
			Details map[string]any
		}
	}
	if json.Unmarshal(a.body, &body) == nil && body.Error.Message != "" {
		e.kind, e.message, e.details = body.Error.Type, body.Error.Message, body.Error.Details
	} else {
		// Cutting the body short may split a character, and the plugin
		// protocol cannot carry a string that is not valid UTF-8.
		text := strings.ToValidUTF8(string(a.body[:min(len(a.body), 200)]), "")
		e.kind, e.message = http.StatusText(a.status), strings.TrimSpace(text)
	}
	return e
}

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
