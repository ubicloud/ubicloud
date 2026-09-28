package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const body = `runner_cpu_jiffies_total{mode="user"} 120
runner_cpu_jiffies_total{mode="guest"} 5
runner_memory_total_bytes 8000000000
runner_memory_available_bytes{mode="user"} 1
runner_disk_avail_bytes 12.5
other_metric 7
runner_disk_size_bytes{vm="spoofed"} 3
`

var testNow = time.Date(2026, 9, 21, 14, 13, 20, 123456000, time.UTC)

func newTestListener(t *testing.T) *listener {
	t.Helper()
	dir := t.TempDir()
	for _, sub := range []string{"pending", "done"} {
		if err := os.Mkdir(filepath.Join(dir, sub), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "labels.json"), []byte(`{"vm":"vm123"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := newListener(dir)
	if err != nil {
		t.Fatal(err)
	}
	l.now = func() time.Time { return testNow }
	return l
}

func post(l *listener, method, path, requestBody string) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	l.handler().ServeHTTP(recorder, httptest.NewRequest(method, path, strings.NewReader(requestBody)))
	return recorder
}

func doneFiles(t *testing.T, l *listener) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(l.metricsDir, "done"))
	if err != nil {
		t.Fatal(err)
	}
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

func TestFormatLabelsSortsAndEscapes(t *testing.T) {
	got := formatLabels(map[string]string{"vm": "vm123", "arch": "a\"b\\c\nd"})
	want := `arch="a\"b\\c\nd",vm="vm123"`
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestNewListenerFailsWithoutLabels(t *testing.T) {
	if _, err := newListener(t.TempDir()); !os.IsNotExist(err) {
		t.Fatalf("got %v, want a not exist error", err)
	}
}

func TestNewListenerFailsWithInvalidLabels(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "labels.json"), []byte(`{"vm":1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := newListener(dir)
	if err == nil || !strings.HasPrefix(err.Error(), "parsing labels.json: ") {
		t.Fatalf("got %v, want a parsing error", err)
	}
}

func TestToPrometheusKeepsAllowlistedLinesAndStampsLabels(t *testing.T) {
	got := newTestListener(t).toPrometheus(body, 1000)
	want := `runner_cpu_jiffies_total{vm="vm123",mode="user"} 120 1000
runner_memory_total_bytes{vm="vm123"} 8000000000 1000
runner_disk_avail_bytes{vm="vm123"} 12.5 1000
`
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestPostWritesScrapeToDoneDirectory(t *testing.T) {
	l := newTestListener(t)

	recorder := post(l, http.MethodPost, "/metrics", body)

	if recorder.Code != http.StatusNoContent {
		t.Fatalf("got status %d, want %d", recorder.Code, http.StatusNoContent)
	}
	files := doneFiles(t, l)
	if len(files) != 1 || files[0] != "2026-09-21T14-13-20-123456.prom" {
		t.Fatalf("got done files %v", files)
	}
	content, err := os.ReadFile(filepath.Join(l.metricsDir, "done", files[0]))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != l.toPrometheus(body, testNow.UnixMilli()) {
		t.Fatalf("got content %q", content)
	}
}

func TestOtherMethodsAreRejected(t *testing.T) {
	recorder := post(newTestListener(t), http.MethodGet, "/metrics", "")
	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("got status %d, want %d", recorder.Code, http.StatusMethodNotAllowed)
	}
}

func TestLargeBodiesAreRejected(t *testing.T) {
	recorder := post(newTestListener(t), http.MethodPost, "/metrics", strings.Repeat("a", maxBodyBytes+1))
	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("got status %d, want %d", recorder.Code, http.StatusRequestEntityTooLarge)
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, os.ErrClosed }

func TestUnreadableBodiesAreRejected(t *testing.T) {
	recorder := httptest.NewRecorder()
	newTestListener(t).handler().ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/metrics", failingReader{}))
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want %d", recorder.Code, http.StatusBadRequest)
	}
}

func TestBodiesWithoutValidMetricsAreRejected(t *testing.T) {
	recorder := post(newTestListener(t), http.MethodPost, "/metrics", "junk\n")
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("got status %d, want %d", recorder.Code, http.StatusBadRequest)
	}
}

func TestRequestsAreRateLimited(t *testing.T) {
	l := newTestListener(t)
	post(l, http.MethodPost, "/metrics", body)
	l.now = func() time.Time { return testNow.Add(time.Second) }

	recorder := post(l, http.MethodPost, "/metrics", body)

	if recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("got status %d, want %d", recorder.Code, http.StatusTooManyRequests)
	}
}

func TestStoreFailuresReturnServerError(t *testing.T) {
	l := newTestListener(t)
	if err := os.Remove(filepath.Join(l.metricsDir, "pending")); err != nil {
		t.Fatal(err)
	}

	recorder := post(l, http.MethodPost, "/metrics", body)

	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("got status %d, want %d", recorder.Code, http.StatusInternalServerError)
	}
}

func TestWriteScrapeKeepsTheNewestDoneFiles(t *testing.T) {
	l := newTestListener(t)
	for i := 0; i < maxDoneFiles+2; i++ {
		if err := l.writeScrape("a 1 1\n", testNow.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatal(err)
		}
	}

	files := doneFiles(t, l)

	if len(files) != maxDoneFiles || files[0] != "2026-09-21T14-13-22-123456.prom" {
		t.Fatalf("got %d files starting with %s", len(files), files[0])
	}
}
