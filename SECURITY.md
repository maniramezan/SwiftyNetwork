# Security Policy

## Supported Versions

Until SwiftyNetwork reaches a `1.0.0` release, only the latest tagged version
on `main` receives security fixes.

| Version | Supported          |
| ------- | ------------------ |
| latest `main` | :white_check_mark: |
| earlier | :x:                |

## Reporting a Vulnerability

If you discover a security issue, please **do not** open a public GitHub
issue. Instead, report it privately so we can address it responsibly:

1. Use GitHub's "Report a vulnerability" feature on the
   [Security tab](https://github.com/maniramezan/SwiftyNetwork/security)
   of this repository, **or**
2. Email the maintainer with the subject `SwiftyNetwork security report`.

Please include:

- A clear description of the vulnerability and its impact.
- Steps to reproduce, ideally with a minimal Swift sample.
- The version / commit hash you tested against.
- Any suggested mitigation, if you have one.

You can expect:

- Acknowledgement within **5 business days**.
- A status update within **14 days** of the initial report.
- A coordinated disclosure timeline once the issue has been validated.

## Scope

In-scope issues include, but are not limited to:

- Bugs that allow leaking authorization tokens, refresh tokens, or other
  credentials through logs, errors, or telemetry.
- Logic errors in `OAuthAuthorizationProvider` or `AuthorizationType`
  that bypass authorization or apply the wrong credential.
- Cache implementations returning data for the wrong key.
- URL construction issues that route requests to unintended hosts.

Out-of-scope:

- Vulnerabilities in third-party Swift toolchains, `URLSession`, or the
  underlying OS networking stack.
- Configuration issues in consumer apps that expose credentials despite
  using SwiftyNetwork's APIs correctly.

## Safe Harbor

We support good-faith security research. As long as you make a reasonable
effort to avoid privacy violations, data destruction, and service
disruption while researching, we will not pursue legal action against
you for your report.

## Integration boundaries

- Use HTTPS for sensitive traffic. Endpoint validation also permits HTTP.
- Scope credentialed clients to trusted origins. TLS pinning is not an origin
  allowlist; unlisted and redirected hosts use URLSession's normal handling.
  Applications using custom credential headers should enforce redirect policy
  through an appropriately configured session delegate.
- Exact pinning policies override ancestor policies; otherwise the nearest
  ancestor allowing subdomains wins. Keep default trust validation enabled.
- Instrumentation receives complete URLs and errors, which may include response
  bodies. Redact before exporting telemetry. Unified logging privacy annotations
  do not remove secrets from the original values.
- Partition cache keys by account/tenant and clear sensitive data on logout.
  RemoteDataCache keys only by URL; isolate instances for authenticated content.
- Encrypt sensitive durable mutations, including captured authorization and body
  data. Persistence and retry do not guarantee exactly-once server execution.
