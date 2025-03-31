# ubi

`ubi` the command line program for interacting with Ubicloud.

# Building

With `make`:

```
$ make
```

Directly with `go build`:

```
$ go build -ldflags "-s -w -X main.version=`cat version.txt`" -tags osusergo,netgo
```

# Running

First, make sure `UBI_TOKEN` in the environment is set to your Ubicloud personal
access token. Then run it:

```
$ ubi
```

# License

APGL
