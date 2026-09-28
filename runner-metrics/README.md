# runner-metrics

`runner-metrics` runs on a Ubicloud host inside a GitHub runner VM's network
namespace. It accepts resource metrics the guest posts to
`http://[fd00:0b1c:100d:57a7::]:9000/metrics`, keeps allowlisted metrics,
stamps them with the VM's labels from `METRICS_DIR/labels.json`, and writes
them to `METRICS_DIR/done` for the host to forward to VictoriaMetrics.

# Building

```
$ go build -ldflags "-s -w -X main.version=`cat version.txt`"
```

# Running

```
$ runner-metrics METRICS_DIR
```

# License

AGPL
