# Channel Extra Settings

This document defines optional channel parameters. It is configured as a JSON object and currently includes the following options.

1. force_format
   - Indicates whether output should be forced into OpenAI-compatible format.
   - Boolean value.
   - Set to `true` to enable forced formatting.

2. proxy
   - Configures a network proxy.
   - String value supporting `http`, `https`, `socks5`, and `socks5h` protocols.
   - The saved value must include protocol and host. Only an empty path or `/` is allowed.
   - Query strings and fragments are not allowed.
   - If no port is provided for SOCKS, runtime defaults to port `1080`.

3. thinking_to_content
   - Converts `reasoning_content` into a `<think>` wrapped segment and appends it to the returned content.
   - Boolean value.
   - Set to `true` to enable this behavior.

---

## JSON Example

Below is a sample configuration enabling forced formatting and setting a proxy URL:

```json
{
    "force_format": true,
    "thinking_to_content": true,
    "proxy": "socks5://proxy.example:1080"
}
```

---

You can control channel behavior by adjusting the JSON values, including whether formatting is forced and which network proxy is used.

## Upgrade Compatibility

Legacy versions ignore path, query, and fragment in proxy URLs. To avoid breaking existing traffic after upgrade, runtime continues to strip those suffixes and logs a single warning once per unique proxy per process for entries without credentials and without suffixes. This compatibility layer does not rewrite any database records.

When saving an updated channel configuration, update the proxy URL to the strict format above.

The proxy connection uses a 30-second TCP dial timeout, 30-second keep-alive timeout, and 10-second TLS handshake timeout. These timeouts also apply to relay requests when a channel proxy is not configured.
