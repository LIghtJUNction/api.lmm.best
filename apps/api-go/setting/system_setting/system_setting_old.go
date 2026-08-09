package system_setting

import (
	"fmt"
	"net/url"
	"os"
	"strings"
)

// ServerAddress is intentionally empty until an operator configures the
// public origin in the database or through SERVER_ADDRESS.  Baking a local
// development URL into the backend makes production OAuth and callback URLs
// silently point at localhost.
var ServerAddress string

const serverAddressEnv = "SERVER_ADDRESS"

// InitServerAddressFromEnv loads the optional deployment fallback before
// database-backed options are applied.  A non-empty database option therefore
// remains authoritative, while a missing option can still use the environment
// without embedding a public URL in the binary.
func InitServerAddressFromEnv() error {
	ServerAddress = ""
	raw := strings.TrimSpace(os.Getenv(serverAddressEnv))
	if raw == "" {
		return nil
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("%s must be an absolute HTTP(S) URL without credentials, query, or fragment", serverAddressEnv)
	}
	ServerAddress = strings.TrimRight(parsed.String(), "/")
	return nil
}

var WorkerUrl = ""
var WorkerValidKey = ""
var WorkerAllowHttpImageRequestEnabled = false

func EnableWorker() bool {
	return WorkerUrl != ""
}
