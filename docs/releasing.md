# Releasing Klenod

Klenod publishes all package gems from `.github/workflows/release.yml`. A release is built from a version tag and uses RubyGems.org Trusted Publishing; it does not require a long-lived API key.

## One-time setup

Create a GitHub environment named `release`. The environment can require approval and should restrict deployments to version tags.

Configure the `release.yml` workflow as a trusted publisher for each existing gem, or as a pending trusted publisher before its first release:

- `klenod`
- `klenod-runtime`
- `klenod-build`
- `klenod-rack`
- `klenod-plugin-css`
- `klenod-plugin-javascript`

Use `release` as the environment name in each RubyGems.org publisher configuration.

## Creating a release

Update `KLENOD_VERSION` and synchronize the generated version constants:

```sh
bundle exec rake version:sync
bundle exec rake version:check
```

Commit the version change, then create and push an annotated tag whose name exactly matches `v#{KLENOD_VERSION}`:

```sh
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin main v0.1.0
```

The release workflow verifies the tag and test suite, builds source and native gems in parallel, verifies the complete artifact inventory, publishes the gems in dependency order, and finally creates a GitHub release containing the gems and `SHA256SUMS`.

## Retrying publication

The publish job never rebuilds gems. It downloads the verified workflow artifact and compares every gem name, version, platform, and SHA-256 with RubyGems.org before pushing. A matching published artifact is skipped; a checksum mismatch fails the release.

If publishing fails, fix the trusted-publisher or GitHub environment configuration and use **Re-run failed jobs** on the original workflow run. The successful build jobs and their artifacts are reused.
