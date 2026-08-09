package appcli

import (
	"bytes"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"golang.org/x/net/http/httpguts"
)

const (
	defaultBaseURL = "http://127.0.0.1:3000"
	maxTokenBytes  = 64 << 10
	maxHeaderBytes = 1 << 20
)

var methodPattern = regexp.MustCompile(`^[A-Za-z]+$`)

type stringList []string

func (values *stringList) String() string {
	return strings.Join(*values, ",")
}

func (values *stringList) Set(value string) error {
	*values = append(*values, value)
	return nil
}

type requestOptions struct {
	URL         string
	BaseURL     string
	Path        string
	Method      string
	Body        string
	BodyFile    string
	HeaderFile  string
	TokenFile   string
	TokenEnv    string
	CookieFile  string
	OutputFile  string
	StatusFile  string
	Headers     stringList
	JSON        bool
	Fail        bool
	ShowStatus  bool
	InsecureTLS bool
	NoFollow    bool
	Timeout     time.Duration
}

// RunRequest performs one native HTTP request and returns a process exit code.
func RunRequest(args []string, version string, stdout, stderr io.Writer) int {
	options, err := parseRequestOptions(args, stderr)
	if errors.Is(err, flag.ErrHelp) {
		return ExitOK
	}
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "%s request: %v\n", ProgramName, err)
		return ExitUsage
	}
	status, err := executeRequest(options, version, stdout)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "%s request: %v\n", ProgramName, sanitizeRequestError(err))
		return ExitError
	}
	if options.ShowStatus {
		_, _ = fmt.Fprintf(stderr, "HTTP_STATUS=%d\n", status)
	}
	if options.Fail && status >= http.StatusBadRequest {
		return ExitHTTPFailure
	}
	return ExitOK
}

func parseRequestOptions(args []string, stderr io.Writer) (requestOptions, error) {
	options := requestOptions{Method: http.MethodGet, Timeout: 30 * time.Second}
	flags := flag.NewFlagSet("request", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.StringVar(&options.URL, "url", "", "full HTTP(S) URL")
	flags.StringVar(&options.BaseURL, "base-url", "", "base HTTP(S) URL")
	flags.StringVar(&options.Path, "path", "", "request path")
	flags.StringVar(&options.Method, "method", http.MethodGet, "HTTP method")
	flags.StringVar(&options.Method, "X", http.MethodGet, "HTTP method")
	flags.StringVar(&options.Body, "body", "", "inline request body")
	flags.StringVar(&options.Body, "d", "", "inline request body")
	flags.StringVar(&options.BodyFile, "body-file", "", "request body file")
	flags.StringVar(&options.HeaderFile, "header-file", "", "file containing one header per line")
	flags.StringVar(&options.TokenFile, "token-file", "", "bearer token file")
	flags.StringVar(&options.TokenEnv, "token-env", "", "environment variable containing a bearer token")
	flags.StringVar(&options.CookieFile, "cookie-file", "", "private persistent cookie store")
	flags.StringVar(&options.OutputFile, "output", "", "response body output file")
	flags.StringVar(&options.OutputFile, "o", "", "response body output file")
	flags.StringVar(&options.StatusFile, "status-file", "", "numeric response status output file")
	flags.Var(&options.Headers, "header", "request header (repeatable)")
	flags.Var(&options.Headers, "H", "request header (repeatable)")
	flags.BoolVar(&options.JSON, "json", false, "set JSON Accept and Content-Type headers")
	flags.BoolVar(&options.Fail, "fail", false, "exit 22 after writing an HTTP error response")
	flags.BoolVar(&options.ShowStatus, "show-status", false, "write the numeric status to stderr")
	flags.BoolVar(&options.InsecureTLS, "insecure", false, "skip TLS certificate verification")
	flags.BoolVar(&options.NoFollow, "no-follow", false, "do not follow redirects")
	flags.DurationVar(&options.Timeout, "timeout", 30*time.Second, "whole-request timeout")
	flags.Usage = func() {
		_, _ = fmt.Fprintf(stderr, "Usage: %s request [options] [URL-or-path]\n", ProgramName)
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		return requestOptions{}, err
	}
	if flags.NArg() > 1 {
		return requestOptions{}, fmt.Errorf("expected at most one URL or path argument")
	}
	if flags.NArg() == 1 {
		if options.URL != "" || options.Path != "" {
			return requestOptions{}, fmt.Errorf("positional URL or path conflicts with --url or --path")
		}
		positional := flags.Arg(0)
		if strings.HasPrefix(positional, "http://") || strings.HasPrefix(positional, "https://") {
			options.URL = positional
		} else {
			options.Path = positional
		}
	}
	if options.Timeout < 0 {
		return requestOptions{}, fmt.Errorf("--timeout must not be negative (zero disables it)")
	}
	if options.Body != "" && options.BodyFile != "" {
		return requestOptions{}, fmt.Errorf("--body and --body-file are mutually exclusive")
	}
	if options.TokenFile != "" && options.TokenEnv != "" {
		return requestOptions{}, fmt.Errorf("--token-file and --token-env are mutually exclusive")
	}
	if options.URL != "" && (options.BaseURL != "" || options.Path != "") {
		return requestOptions{}, fmt.Errorf("--url cannot be combined with --base-url or --path")
	}
	if !methodPattern.MatchString(options.Method) {
		return requestOptions{}, fmt.Errorf("HTTP method must contain only letters")
	}
	options.Method = strings.ToUpper(options.Method)
	return options, nil
}

func executeRequest(options requestOptions, version string, stdout io.Writer) (int, error) {
	target, err := resolveRequestURL(options)
	if err != nil {
		return 0, err
	}

	body, closeBody, err := requestBody(options)
	if err != nil {
		return 0, err
	}
	if closeBody != nil {
		defer closeBody()
	}

	request, err := http.NewRequest(options.Method, target.String(), body)
	if err != nil {
		return 0, fmt.Errorf("create request: %w", err)
	}
	request.Header.Set("User-Agent", ProgramName+"/"+version)
	if err := applyHeaders(request, options); err != nil {
		return 0, err
	}
	if err := applyBearerToken(request, options); err != nil {
		return 0, err
	}

	jar, err := newPersistentJar(options.CookieFile)
	if err != nil {
		return 0, err
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{
		MinVersion: tls.VersionTLS12,
		// This is an explicit operator-only escape hatch for local certificates.
		InsecureSkipVerify: options.InsecureTLS, //nolint:gosec
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   options.Timeout,
		Jar:       jar,
	}
	client.CheckRedirect = redirectPolicy(options.NoFollow)

	response, requestErr := client.Do(request)
	saveErr := jar.save()
	if requestErr != nil {
		return 0, requestErr
	}
	defer response.Body.Close()
	if saveErr != nil {
		return 0, saveErr
	}
	if err := writeResponseBody(options.OutputFile, response.Body, stdout); err != nil {
		return 0, err
	}
	if options.StatusFile != "" {
		if err := writePrivateFile(options.StatusFile, []byte(fmt.Sprintf("%d\n", response.StatusCode))); err != nil {
			return 0, fmt.Errorf("write status file: %w", err)
		}
	}
	return response.StatusCode, nil
}

func resolveRequestURL(options requestOptions) (*url.URL, error) {
	if options.URL != "" {
		return parseHTTPURL(options.URL)
	}
	baseValue := options.BaseURL
	if baseValue == "" {
		baseValue = os.Getenv("LMM_API_URL")
	}
	if baseValue == "" {
		baseValue = defaultBaseURL
	}
	base, err := parseHTTPURL(baseValue)
	if err != nil {
		return nil, fmt.Errorf("invalid base URL: %w", err)
	}
	if base.RawQuery != "" || base.Fragment != "" {
		return nil, fmt.Errorf("base URL must not contain a query or fragment")
	}
	path := options.Path
	if path == "" {
		path = "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	reference, err := url.Parse(path)
	if err != nil || reference.IsAbs() || reference.Host != "" {
		return nil, fmt.Errorf("invalid request path")
	}
	return parseHTTPURL(base.ResolveReference(reference).String())
}

func parseHTTPURL(value string) (*url.URL, error) {
	parsed, err := url.Parse(value)
	if err != nil {
		return nil, fmt.Errorf("parse URL: %w", err)
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, fmt.Errorf("URL must use http:// or https://")
	}
	if parsed.Host == "" {
		return nil, fmt.Errorf("URL host is required")
	}
	if parsed.User != nil {
		return nil, fmt.Errorf("URL user information is not allowed")
	}
	if parsed.Fragment != "" {
		return nil, fmt.Errorf("URL fragments are not sent in HTTP requests")
	}
	return parsed, nil
}

func requestBody(options requestOptions) (io.Reader, func(), error) {
	if options.BodyFile == "" {
		return strings.NewReader(options.Body), nil, nil
	}
	file, err := openRegularFile(options.BodyFile)
	if err != nil {
		return nil, nil, fmt.Errorf("open body file: %w", err)
	}
	return file, func() { _ = file.Close() }, nil
}

func applyHeaders(request *http.Request, options requestOptions) error {
	headers := append(stringList(nil), options.Headers...)
	if options.HeaderFile != "" {
		data, err := readRequiredRegularFile(options.HeaderFile, maxHeaderBytes)
		if err != nil {
			return fmt.Errorf("read header file: %w", err)
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") {
				headers = append(headers, line)
			}
		}
	}
	for _, line := range headers {
		name, value, ok := strings.Cut(line, ":")
		name = strings.TrimSpace(name)
		value = strings.TrimSpace(value)
		if !ok || !httpguts.ValidHeaderFieldName(name) || !httpguts.ValidHeaderFieldValue(value) {
			return fmt.Errorf("invalid request header")
		}
		if strings.EqualFold(name, "Host") {
			if request.Host != "" && request.Host != request.URL.Host {
				return fmt.Errorf("Host header may only be specified once")
			}
			request.Host = value
			continue
		}
		request.Header.Add(name, value)
	}
	if options.JSON {
		if request.Header.Get("Accept") == "" {
			request.Header.Set("Accept", "application/json")
		}
		if request.Header.Get("Content-Type") == "" {
			request.Header.Set("Content-Type", "application/json")
		}
	}
	return nil
}

func applyBearerToken(request *http.Request, options requestOptions) error {
	if options.TokenFile == "" && options.TokenEnv == "" {
		return nil
	}
	if request.Header.Get("Authorization") != "" {
		return fmt.Errorf("bearer token conflicts with an Authorization header")
	}
	var token string
	if options.TokenFile != "" {
		data, err := readRequiredRegularFile(options.TokenFile, maxTokenBytes)
		if err != nil {
			return fmt.Errorf("read token file: %w", err)
		}
		token = strings.TrimSpace(string(data))
	} else {
		value, ok := os.LookupEnv(options.TokenEnv)
		if !ok {
			return fmt.Errorf("token environment variable is unset")
		}
		token = strings.TrimSpace(value)
	}
	if token == "" || strings.ContainsAny(token, "\r\n") {
		return fmt.Errorf("bearer token is empty or contains a line break")
	}
	request.Header.Set("Authorization", "Bearer "+token)
	return nil
}

func redirectPolicy(noFollow bool) func(*http.Request, []*http.Request) error {
	return func(request *http.Request, previous []*http.Request) error {
		if noFollow {
			return http.ErrUseLastResponse
		}
		if len(previous) >= 10 {
			return fmt.Errorf("stopped after 10 redirects")
		}
		if len(previous) > 0 && !sameOrigin(previous[0].URL, request.URL) {
			request.Header.Del("Authorization")
			request.Header.Del("Cookie")
		}
		return nil
	}
}

func sameOrigin(left, right *url.URL) bool {
	return strings.EqualFold(left.Scheme, right.Scheme) && strings.EqualFold(left.Host, right.Host)
}

func writeResponseBody(path string, body io.Reader, stdout io.Writer) error {
	if path == "" {
		if _, err := io.Copy(stdout, body); err != nil {
			return fmt.Errorf("write response body: %w", err)
		}
		return nil
	}
	if err := writePrivateStream(path, body); err != nil {
		return fmt.Errorf("write response body: %w", err)
	}
	return nil
}

func openRegularFile(path string) (*os.File, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("path is not a regular file")
	}
	return os.Open(path)
}

func readRequiredRegularFile(path string, limit int64) ([]byte, error) {
	file, err := openRegularFile(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if info.Size() > limit {
		return nil, fmt.Errorf("file exceeds %d bytes", limit)
	}
	return io.ReadAll(io.LimitReader(file, limit+1))
}

func writePrivateFile(path string, data []byte) error {
	return writePrivateStream(path, bytes.NewReader(data))
}

func writePrivateStream(path string, content io.Reader) error {
	cleanPath := filepath.Clean(path)
	directory := filepath.Dir(cleanPath)
	base := filepath.Base(cleanPath)
	if info, err := os.Lstat(cleanPath); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("destination is not a regular file")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	temporary, err := os.CreateTemp(directory, "."+base+".tmp-")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return err
	}
	if _, err := io.Copy(temporary, content); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, cleanPath); err != nil {
		return err
	}
	committed = true
	return nil
}

func sanitizeRequestError(err error) error {
	var urlError *url.Error
	if errors.As(err, &urlError) {
		return urlError.Err
	}
	return err
}
