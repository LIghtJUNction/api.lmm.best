# LMM API legacy Go hotfix package

`build-local-package.sh` packages only a prebuilt, version-checked
`../out/lmm-api` binary. It never reads `/etc/lmm-api/lmm-api.env`, builds Go,
downloads sources, restarts `lmm-api.service`, or accesses the SQLite database.

The package declares `etc/lmm-api/lmm-api.env` as a pacman `backup` file. The
currently installed r27 package did not have that metadata, so the install hook
also snapshots the existing file before its first upgrade and restores it after
package extraction. A snapshot contains credentials and must be treated as a
secret. It is stored root-only at:

`/var/lib/lmm-api/package-backups/lmm-api.env.pre-upgrade-<version>`

The directory mode is `0700`; package-hook snapshots are env-only safety copies
and are separate from the complete rollback bundles below. Review and remove
older env-only copies manually as root only after a complete rollback bundle is
verified. Do not copy snapshots into the repository or build output.

On the first r27-to-hotfix upgrade pacman creates `lmm-api.env.pacnew`: it is
the non-secret package template, while the original env is restored from the
snapshot. Inspect it, verify it contains no site configuration, then remove it
manually; later package upgrades retain ordinary pacman `.pacnew` semantics.

Before `pacman -U`, run `backup-server-state.sh --destination /root/rollback/lmm-api`.
It snapshots the binary, unit, env, unit drop-ins, package metadata/integrity,
and an online SQLite `.backup`; it validates `quick_check` and checksums before
retaining only the newest three validated complete snapshot directories.
