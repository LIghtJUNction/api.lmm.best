package system_setting

import "testing"

func TestInitServerAddressFromEnv(t *testing.T) {
	previous := ServerAddress
	t.Cleanup(func() { ServerAddress = previous })

	t.Run("empty value does not invent a local origin", func(t *testing.T) {
		t.Setenv(serverAddressEnv, "")
		ServerAddress = "stale value"
		if err := InitServerAddressFromEnv(); err != nil {
			t.Fatalf("InitServerAddressFromEnv() error = %v", err)
		}
		if ServerAddress != "" {
			t.Fatalf("ServerAddress = %q, want empty", ServerAddress)
		}
	})

	t.Run("normalizes a configured origin", func(t *testing.T) {
		t.Setenv(serverAddressEnv, "https://api.example.com///")
		if err := InitServerAddressFromEnv(); err != nil {
			t.Fatalf("InitServerAddressFromEnv() error = %v", err)
		}
		if ServerAddress != "https://api.example.com" {
			t.Fatalf("ServerAddress = %q, want normalized origin", ServerAddress)
		}
	})

	for _, value := range []string{
		"localhost:3000",
		"ftp://api.example.com",
		"https://user:password@api.example.com",
		"https://api.example.com/callback?next=1",
	} {
		t.Run("rejects "+value, func(t *testing.T) {
			t.Setenv(serverAddressEnv, value)
			if err := InitServerAddressFromEnv(); err == nil {
				t.Fatalf("InitServerAddressFromEnv() accepted %q", value)
			}
		})
	}
}
