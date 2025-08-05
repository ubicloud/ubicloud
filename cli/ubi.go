package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"slices"
	"strings"
)

var version = "undefined"
var allowConfirmation bool = true
var debugEnabled = os.Getenv("UBI_DEBUG") == "1"

func getToken() string {
	token := os.Getenv("UBI_TOKEN")
	if token == "" {
		fmt.Fprintln(os.Stderr, "! Personal access token must be provided in UBI_TOKEN env variable for use")
		os.Exit(1)
	}
	return token
}

func baseURL() string {
	if url := os.Getenv("UBI_URL"); url != "" {
		return url
	}
	return "https://api.ubicloud.com/cli"
}

type Client struct {
	http.Client
	Headers http.Header
}

func NewClient() *Client {
	return &Client{
		Headers: make(http.Header),
	}
}

func sendRequest(args []string) {
	requestBodyHash := make(map[string][]string)
	requestBodyHash["argv"] = args
	request_body, err := json.Marshal(requestBodyHash)
	if err != nil {
		fmt.Fprintf(os.Stderr, "! Error encoding request body\n")
		os.Exit(1)
	}

	client := &http.Client{}
	req, err := http.NewRequest("POST", baseURL(), bytes.NewBuffer(request_body))
	if err != nil {
		fmt.Fprintf(os.Stderr, "! Error creating http request\n")
		os.Exit(1)
	}
	req.Header.Set("Authorization", "Bearer: "+getToken())
	req.Header.Set("X-Ubi-Version", version)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/plain")
	req.Header.Set("Connection", "close")

	debugLog("sending: %+v\n", args)
	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "! Error sending http request\n")
		os.Exit(1)
	}

	processResponse(resp, args)

	err = resp.Body.Close()
	if err != nil {
		fmt.Fprintf(os.Stderr, "! Error closing response body\n")
		os.Exit(1)
	}
}

func main() {
	sendRequest(os.Args[1:])
}

func processResponse(resp *http.Response, args []string) {
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		handleSuccess(resp, args)
	default:
		_, err := io.Copy(os.Stderr, resp.Body)
		if err != nil {
			fmt.Fprintf(os.Stderr, "! Error copying response body to stderr\n")
		}
		os.Exit(1)
	}
}

func handleSuccess(resp *http.Response, args []string) {
	if prog := resp.Header.Get("ubi-command-execute"); prog != "" {
		executeValidatedCommand(prog, resp)
	} else if prompt := resp.Header.Get("ubi-confirm"); prompt != "" {
		handleConfirmation(prompt, resp.Body, args)
	} else {
		_, err := io.Copy(os.Stdout, resp.Body)
		if err != nil {
			fmt.Fprintf(os.Stderr, "! Error copying response body to stdout\n")
		}
	}
}

var allowedCommands = map[string]bool{
	"ssh": true, "scp": true, "sftp": true,
	"psql": true, "pg_dump": true, "pg_dumpall": true,
}

var pgCommands = map[string]bool{
	"psql": true, "pg_dump": true, "pg_dumpall": true,
}

func getExecutablePath(prog string) string {
	envProg := os.Getenv("UBI_" + strings.ToUpper(prog))
	if envProg != "" {
		prog = envProg
	}
	return prog
}

func executeValidatedCommand(prog string, resp *http.Response) {
	args := resp.Body
	if !slices.Contains(os.Args, prog) {
		fmt.Fprintf(os.Stderr, "! Invalid server response, not executing program not in original argv\n")
		os.Exit(1)
	}
	if !allowedCommands[prog] {
		fmt.Fprintf(os.Stderr, "! Invalid server response, unsupported program requested\n")
		os.Exit(1)
	}
	if pgCommands[prog] {
		pgpassword := resp.Header.Get("ubi-pgpassword")
		if pgpassword != "" {
			err := os.Setenv("PGPASSWORD", pgpassword)
			if err != nil {
				fmt.Fprintf(os.Stderr, "! Unable to set PGPASSWORD environment variable: %v\n", err)
				os.Exit(1)
			}
		}
	}

	argsBuf := make([]byte, 1024*1024)
	n, err := args.Read(argsBuf)
	if err != nil && err != io.EOF {
		fmt.Fprintf(os.Stderr, "! Error reading response body: %v\n", err)
		fmt.Println(err)
		os.Exit(1)
	}
	argsBuf = argsBuf[:n]
	cmdArgs := strings.Split(string(argsBuf[:]), "\x00")
	validateArguments(prog, cmdArgs)

	prog = getExecutablePath(prog)
	debugLog("exec: %s %+v\n", prog, cmdArgs)
	cmd := exec.Command(prog, cmdArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			os.Exit(exitError.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "! Error executing program: %v\n", err)
		os.Exit(1)
	}
}

func handleConfirmation(prompt string, body io.Reader, args []string) {
	if !allowConfirmation {
		fmt.Fprintf(os.Stderr, "! Invalid server response, repeated confirmation attempt\n")
		os.Exit(1)
	}

	allowConfirmation = false
	_, err := io.Copy(os.Stdout, body)
	if err != nil {
		fmt.Fprintf(os.Stderr, "! Error copying response body to stdout\n")
		os.Exit(1)
	}
	fmt.Printf("\n%s: ", prompt)

	scanner := bufio.NewScanner(os.Stdin)
	if !scanner.Scan() {
		fmt.Fprintln(os.Stderr, "! Error reading confirmation")
		os.Exit(1)
	}

	confirmation := scanner.Text()
	args = append([]string{"--confirm", confirmation}, args...)
	sendRequest(args)
}

func debugLog(format string, args ...interface{}) {
	if debugEnabled {
		fmt.Printf(format, args...)
	}
}

func validateArguments(prog string, received []string) {
	originalSet := make(map[string]bool)
	for _, arg := range os.Args {
		originalSet[arg] = true
	}

	//debugLog("original: %+v\n", os.Args)
	//debugLog("received: %+v\n", received)

	seenCustom := false
	pg_dumpall := false
	seenSep := false
	invalid_message := ""

	for _, arg := range received {
		if arg == "--" {
			seenSep = true
		} else if !originalSet[arg] {
			if seenCustom {
				invalid_message = "! Invalid server response, multiple arguments not in submitted argv"
				break
			} else if seenSep {
				seenCustom = true
			} else if prog == "pg_dumpall" && strings.HasPrefix(arg, "-d") {
				seenCustom = true
				pg_dumpall = true
			} else {
				invalid_message = "! Invalid server response, argument before '--' not in submitted argv"
				break
			}
		}
	}

	if !seenSep && !pg_dumpall && invalid_message == "" {
		invalid_message = "! Invalid server response, no '--' in returned argv"
	}

	if invalid_message != "" {
		debugLog("failure: %s %v", getExecutablePath(prog), received)
		fmt.Fprintln(os.Stderr, invalid_message)
		os.Exit(1)
	}
}
