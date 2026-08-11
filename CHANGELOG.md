# Changelog

All notable user-facing and operational changes are recorded here. The
administrator can publish the matching release note from system settings;
authenticated users then see it once after their next login.

## Unreleased

- Added the L0 AI assistant entry flow. L0 users can browse the permitted
  read-only areas and use the assistant to prepare an upgrade request; console,
  key creation, payment, plan and discount actions remain unavailable until an
  administrator approves L1 access.
- Added context-aware assistant guidance for setup, model IDs, base URL,
  API-key creation, package selection, discounts, invitations, open-source
  bounties and historical usage analysis. Sensitive credentials, raw OAuth
  subjects, balances and conversation contents are excluded from the context.
- Added normalized question caching, user-context isolation, configurable
  assistant personas/tools and super-administrator funding for assistant
  relay usage. Cache hits now avoid duplicate assistant-intent database writes
  while preserving exact response bytes.
- Added the Anthropic-aligned advanced security policy with an Aho-Corasick
  matcher, audit/block actions, digest-only event records, public risk
  statistics and administrator configuration.
- Added a production-operator customer profile so benign questions about
  reliability, concurrency, rate limits and observability are not mistaken for
  abuse; bypass, scanning and brute-force language still follows the security
  risk path.
- Tightened administrator handoffs so the request is required and contains at
  least five characters at the AI tool, browser form and API validation layers;
  security-risk signals now take precedence over promotion-seeking signals.
- Added release-note delivery and acknowledgement so a published changelog is
  shown after the user's next login and not repeatedly during an active session.
- Improved level, payment-visibility, administrator, mobile and chart-display
  behavior, including safer contrast for stacked usage charts.
- Standardized production operations on the native `lmm-api-go` CLI, with
  checks for package integrity, service health, resource pressure and rollback
  evidence before release promotion.

### Verification

- Go controller, service, setting and model tests pass.
- Frontend build check and targeted assistant tests pass.
- Shell-only operator persona acceptance tests pass for technical, guided
  buyer, promotion, security, normal, mobile, privacy and screen-reader
  profiles.
