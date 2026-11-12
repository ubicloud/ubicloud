package provider

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

// fakeAPI answers each "METHOD path" with its replies in turn, repeating the
// last, and records every request as "METHOD path body". A path with no
// replies answers 404, and a reply with status 0 drops the connection.
type fakeAPI struct {
	*httptest.Server
	mu      sync.Mutex
	replies map[string][]reply
	seen    []string
	headers []http.Header
}

type reply struct {
	status     int
	body       string
	retryAfter string
}

const notFound = `{"error":{"code":404,"type":"ResourceNotFound","message":"not found"}}`

func newFakeAPI(t *testing.T, replies map[string][]reply) *fakeAPI {
	f := &fakeAPI{replies: replies}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		key := r.Method + " " + r.URL.Path
		f.mu.Lock()
		f.seen = append(f.seen, strings.TrimSpace(key+" "+string(body)))
		f.headers = append(f.headers, r.Header)
		rep := reply{404, notFound, ""}
		if rs := f.replies[key]; len(rs) > 0 {
			rep = rs[0]
			if len(rs) > 1 {
				f.replies[key] = rs[1:]
			}
		}
		f.mu.Unlock()
		if rep.status == 0 {
			conn, _, _ := w.(http.Hijacker).Hijack()
			conn.Close()
			return
		}
		if rep.retryAfter != "" {
			w.Header().Set("Retry-After", rep.retryAfter)
		}
		w.WriteHeader(rep.status)
		io.WriteString(w, rep.body)
	}))
	t.Cleanup(f.Close)
	return f
}

func (f *fakeAPI) client() *client {
	return &client{endpoint: f.URL, token: "tok", projectID: "p1", userAgent: "ua/1", poll: time.Millisecond, http: f.Client()}
}

func (f *fakeAPI) requests() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.seen, "\n")
}

func (f *fakeAPI) attempts() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.seen)
}

func (f *fakeAPI) header(i int, name string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.headers[i].Get(name)
}

func tfStr(s string) tftypes.Value { return tftypes.NewValue(tftypes.String, s) }

func TestFill(t *testing.T) {
	c := &client{projectID: "p 1"}
	got, err := c.fill("/{project_id}/location/{location}/x/{id}", values{"location": tfStr("l1"), "id": tfStr("a/b")})
	if want := "/p%201/location/l1/x/a%2Fb"; got != want || err != nil {
		t.Errorf("fill = %q, %v; want %q", got, err, want)
	}
	unknown := tftypes.NewValue(tftypes.String, tftypes.UnknownValue)
	for _, vals := range []values{{}, {"id": tftypes.NewValue(tftypes.String, nil)}, {"id": unknown}} {
		if _, err := c.fill("/x/{id}", vals); err == nil || !strings.Contains(err.Error(), "{id}") {
			t.Errorf("fill(%v) error = %v", vals, err)
		}
	}
}

func TestRequestHeadersAndNumbers(t *testing.T) {
	api := newFakeAPI(t, map[string][]reply{"POST /x": {{200, `{"n": 12345678901234567890}`, ""}}})
	body, err := api.client().do(context.Background(), request{method: "POST", path: "/x", body: map[string]any{"n": json.Number("9007199254740993")}})
	if err != nil || body["n"] != json.Number("12345678901234567890") {
		t.Fatalf("do = %v, %v", body, err)
	}
	for name, want := range map[string]string{"Authorization": "Bearer tok", "User-Agent": "ua/1", "Accept": "application/vnd.ubicloud+json; version=2", "Content-Type": "application/json"} {
		if got := api.header(0, name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if got := api.requests(); got != `POST /x {"n":9007199254740993}` {
		t.Errorf("sent %s", got)
	}
}

func TestRetry(t *testing.T) {
	conflict := reply{409, `{"error":{"code":409,"type":"Busy","message":"try later"}}`, ""}
	busy := conflict
	busy.retryAfter = "0"
	ok := reply{200, `{"id":"a1"}`, ""}
	unavailable := reply{503, "upstream down", ""}
	tests := []struct {
		name     string
		req      request
		replies  []reply
		attempts int
		want     string // "" for success, else a substring of the error
	}{
		{"a refusal is repeated, creates included", request{method: "POST", once: true}, []reply{busy, busy, ok}, 3, ""},
		{"a 429 is repeated", request{method: "GET"}, []reply{{429, "", ""}, ok}, 2, ""},
		{"a 503 is repeated for a read", request{method: "GET"}, []reply{unavailable, ok}, 2, ""},
		{"a 503 makes a create ambiguous", request{method: "POST", once: true}, []reply{unavailable, ok}, 1, "ambiguous"},
		{"a dropped connection is repeated for a verb", request{method: "PATCH"}, []reply{{}, ok}, 2, ""},
		{"a dropped connection makes a create ambiguous", request{method: "POST", once: true}, []reply{{}, ok}, 1, "ambiguous"},
		{"an undecodable 2xx makes a create ambiguous", request{method: "POST", once: true}, []reply{{200, "[1]", ""}, ok}, 1, "ambiguous"},
		{"an undecodable 2xx is reported for a read", request{method: "GET"}, []reply{{200, "[1]", ""}, ok}, 1, "does not decode"},
		{"five failures in a row end the request", request{method: "GET"}, []reply{unavailable}, 5, "after 5 attempts"},
		{"a 500 is reported", request{method: "GET"}, []reply{{500, "", ""}, ok}, 1, "500 Internal Server Error"},
		{"an error body is decoded", request{method: "GET"}, []reply{conflict}, 1, "GET /x: 409 Busy: try later"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			api := newFakeAPI(t, map[string][]reply{tt.req.method + " /x": tt.replies})
			tt.req.path = "/x"
			_, err := api.client().do(context.Background(), tt.req)
			if (err != nil) != (tt.want != "") || !strings.Contains(describeErr(err), tt.want) {
				t.Errorf("error = %v, want %q", describeErr(err), tt.want)
			}
			if n := api.attempts(); n != tt.attempts {
				t.Errorf("%d attempts, want %d", n, tt.attempts)
			}
		})
	}
}

func TestErrorBodyCut(t *testing.T) {
	text := strings.Repeat("a", 199)
	api := newFakeAPI(t, map[string][]reply{"GET /x": {{418, text + "é", ""}}})
	_, err := api.client().do(context.Background(), request{method: "GET", path: "/x"})
	if want := "GET /x: 418 I'm a teapot: " + text; err == nil || err.Error() != want {
		t.Errorf("error = %q, want the body cut before the character the limit splits", err)
	}
}

func describeErr(err error) string {
	if err == nil {
		return ""
	}
	if errors.As(err, new(*ambiguousError)) {
		return "ambiguous: " + err.Error()
	}
	return err.Error()
}

func TestRetryWithoutConnection(t *testing.T) {
	api := newFakeAPI(t, nil)
	closed := api.client()
	api.Close()
	malformed := api.client()
	malformed.endpoint = "http://a b"
	for _, c := range []*client{closed, malformed} {
		_, err := c.do(context.Background(), request{method: "POST", path: "/x", once: true})
		if err == nil || errors.As(err, new(*ambiguousError)) || !strings.Contains(err.Error(), "after 5 attempts") {
			t.Errorf("error = %v, want five unambiguous attempts", err)
		}
	}
}

func TestRetryUntilDeadline(t *testing.T) {
	api := newFakeAPI(t, map[string][]reply{"GET /x": {{429, "", "1"}}})
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := api.client().do(ctx, request{method: "GET", path: "/x"})
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "429") {
		t.Errorf("error = %v", err)
	}

	hung := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer hung.Close()
	ctx, cancel = context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err = (&client{endpoint: hung.URL, poll: time.Millisecond, http: hung.Client()}).do(ctx, request{method: "GET", path: "/x"})
	if !errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), "the last answer") {
		t.Errorf("error = %v, want the request in flight at the deadline, not repeated", err)
	}
}
