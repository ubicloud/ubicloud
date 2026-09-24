# Gateway language benchmark

Two minimal TLS-splicing gateways with identical behaviour — terminate the
client's TLS, dial TLS upstream, splice both ways — so the cost of the
double-TLS hop the design's trust model forces (section 8.3) can be compared
between a compiled binary and Ruby.

SNI parsing and the PostgreSQL SSLRequest preamble are deliberately omitted:
they cost the same in both implementations and are not what distinguishes them.

    bash run.sh        # builds, runs both, prints latency, throughput, RSS

Results and interpretation are in ../FINDINGS.md, section 2.12.
