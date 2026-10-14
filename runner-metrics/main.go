// runner-metrics runs inside a runner VM's network namespace on the host.
// It accepts resource metrics posted by the guest, keeps allowlisted
// metrics, stamps them with the VM's labels, and writes them to files
// that the host forwards to VictoriaMetrics.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

var version = "dev"

const (
	listenAddr   = "[fd00:0b1c:100d:57a7::]:9000"
	maxBodyBytes = 64 * 1024
	minInterval  = 4 * time.Second
	maxDoneFiles = 120
)

var allowedMetrics = map[string]bool{
	"runner_cpu_jiffies_total":              true,
	"runner_memory_total_bytes":             true,
	"runner_memory_available_bytes":         true,
	"runner_disk_size_bytes":                true,
	"runner_disk_avail_bytes":               true,
	"runner_network_receive_bytes_total":    true,
	"runner_network_transmit_bytes_total":   true,
	"runner_network_receive_packets_total":  true,
	"runner_network_transmit_packets_total": true,
}

var cpuModes = map[string]bool{
	"user": true, "nice": true, "system": true, "idle": true,
	"iowait": true, "irq": true, "softirq": true, "steal": true,
}

var lineRegexp = regexp.MustCompile(`^([a-z_]+)(?:\{mode="([a-z]+)"\})? (\d+(?:\.\d+)?)$`)

var labelValueEscaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)

type listener struct {
	metricsDir   string
	labels       string
	now          func() time.Time
	mu           sync.Mutex
	lastAccepted time.Time
}

func formatLabels(labels map[string]string) string {
	keys := make([]string, 0, len(labels))
	for key := range labels {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf(`%s="%s"`, key, labelValueEscaper.Replace(labels[key])))
	}
	return strings.Join(parts, ",")
}

func newListener(metricsDir string) (*listener, error) {
	data, err := os.ReadFile(filepath.Join(metricsDir, "labels.json"))
	if err != nil {
		return nil, err
	}
	var labels map[string]string
	if err := json.Unmarshal(data, &labels); err != nil {
		return nil, fmt.Errorf("parsing labels.json: %w", err)
	}
	return &listener{metricsDir: metricsDir, labels: formatLabels(labels), now: time.Now}, nil
}

func (l *listener) toPrometheus(body string, timestampMs int64) string {
	var out strings.Builder
	for _, line := range strings.Split(body, "\n") {
		match := lineRegexp.FindStringSubmatch(strings.TrimSpace(line))
		if match == nil || !allowedMetrics[match[1]] {
			continue
		}
		name, mode, value := match[1], match[2], match[3]

		if name == "runner_cpu_jiffies_total" {
			if cpuModes[mode] {
				fmt.Fprintf(&out, "%s{%s,mode=\"%s\"} %s %d\n", name, l.labels, mode, value, timestampMs)
			}
		} else if mode == "" {
			fmt.Fprintf(&out, "%s{%s} %s %d\n", name, l.labels, value, timestampMs)
		}
	}
	return out.String()
}

func writeSynced(path, content string) (err error) {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := file.Close(); err == nil {
			err = closeErr
		}
	}()

	if _, err = file.WriteString(content); err != nil {
		return err
	}
	return file.Sync()
}

func (l *listener) writeScrape(content string, now time.Time) error {
	utc := now.UTC()
	filename := fmt.Sprintf("%s-%06d.prom", utc.Format("2006-01-02T15-04-05"), utc.Nanosecond()/1000)
	pendingPath := filepath.Join(l.metricsDir, "pending", filename)
	donePath := filepath.Join(l.metricsDir, "done", filename)

	if err := writeSynced(pendingPath, content); err != nil {
		return err
	}
	if err := os.Rename(pendingPath, donePath); err != nil {
		return err
	}

	doneFiles, err := os.ReadDir(filepath.Join(l.metricsDir, "done"))
	if err != nil {
		return err
	}
	for i := 0; i < len(doneFiles)-maxDoneFiles; i++ {
		if err := os.Remove(filepath.Join(l.metricsDir, "done", doneFiles[i].Name())); err != nil {
			return err
		}
	}
	return nil
}

func (l *listener) handleMetrics(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
		} else {
			http.Error(w, "failed to read body", http.StatusBadRequest)
		}
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	if !l.lastAccepted.IsZero() && now.Sub(l.lastAccepted) < minInterval {
		http.Error(w, "too many requests", http.StatusTooManyRequests)
		return
	}

	content := l.toPrometheus(string(body), now.UnixMilli())
	if content == "" {
		http.Error(w, "no valid metrics", http.StatusBadRequest)
		return
	}

	if err := l.writeScrape(content, now); err != nil {
		log.Printf("writing scrape failed: %v", err)
		http.Error(w, "failed to store metrics", http.StatusInternalServerError)
		return
	}

	l.lastAccepted = now
	w.WriteHeader(http.StatusNoContent)
}

func (l *listener) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /metrics", l.handleMetrics)
	return mux
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: runner-metrics METRICS_DIR")
		os.Exit(2)
	}

	l, err := newListener(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}

	server := &http.Server{
		Addr:              listenAddr,
		Handler:           l.handler(),
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		MaxHeaderBytes:    4096,
	}
	log.Printf("runner-metrics %s listening on %s", version, listenAddr)
	log.Fatal(server.ListenAndServe())
}
