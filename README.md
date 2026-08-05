<div align="center">

# LMM Forge

**Open-source bounty collaboration and delivery tracking.**

</div>

> **Access policy:** Access from China is prohibited.

## What LMM Forge does

LMM Forge gives maintainers and contributors one accountable workflow for funded open-source work:

- publish a repository challenge with a defined scope, reward, delivery slots, and acceptance rules;
- accept funded work with a verifiable GitHub identity;
- attach Issue and pull request evidence to a delivery;
- review work and release escrowed rewards;
- preserve settlement, rating, tip, and dispute events in the same evidence trail.

The public challenge board is readable without an account. Signing in enables challenge acceptance and wallet funding. A new account receives permanent developer-console access after creating its first credential; no deposit is required for activation. Existing accounts and administrators retain their established access.

## Repository layout

| Path | Role |
| --- | --- |
| [`apps/web`](./apps/web) | Shared React frontend and LMM Forge product experience |
| [`apps/api-go`](./apps/api-go) | Default production backend and bounty settlement implementation |
| [`apps/api-rust`](./apps/api-rust) | Optional Rust preview backend and compatibility tooling |

The default production build compiles `apps/web`, synchronizes the verified assets into the Go embed tree, and then builds the Go service. The Rust backend remains opt-in and does not replace the default image or release path.

## Quick start

Review [`.env.example`](./.env.example), replace all example credentials, and then start the default stack:

```bash
git clone https://github.com/LIghtJUNction/api.lmm.best.git
cd api.lmm.best
docker compose up -d
```

Open <http://localhost:3000> and complete the setup flow. Common development commands are:

```bash
just setup
just dev
just test
just build
```

`just build` produces the shared frontend, synchronizes it into `apps/api-go/web/dist`, and builds the default Go executable. PostgreSQL and Valkey are the default Compose services; the Go backend also retains its inherited SQLite and MySQL compatibility.

## Production notes

Before exposing a deployment:

1. Enforce the access policy at the network edge in addition to displaying the notice in the application.
2. Replace every example database, cache, and session secret.
3. Terminate HTTPS at a trusted reverse proxy and configure exact trusted origins and proxy ranges.
4. Keep PostgreSQL and Valkey on private networks and test database restoration.
5. Review challenge escrow, wallet, rate-limit, logging, retention, and dispute settings.

Application copy is not a substitute for geographic enforcement. Operators are responsible for implementing and maintaining any required IP, account, payment, and legal controls.

## Technical foundation

LMM Forge is the product layer maintained in this repository. Its service foundation is derived from [QuantumNous/New API](https://github.com/QuantumNous/new-api), which builds on [One API](https://github.com/songquanpeng/one-api). The inherited New API compatibility layer, identifiers, copyright notices, and attribution remain intact.

For deployment and authentication details, see [`docs/authentication.md`](./docs/authentication.md), [`NOTICE`](./NOTICE), and [`THIRD-PARTY-LICENSES.md`](./THIRD-PARTY-LICENSES.md).

## License and attribution

This repository is licensed under the [GNU Affero General Public License v3.0](./LICENSE). Preserve the required QuantumNous/New API and One API notices, the visible upstream attribution, and all applicable third-party terms when redistributing a modified build.
