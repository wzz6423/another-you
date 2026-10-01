# Security policy

**English** | [简体中文](SECURITY.zh-CN.md)

## Scope

Another You is a 0.1.0 development preview. Security work currently targets the code on `main`; there is no maintained stable-release series or fixed response-time commitment.

The current boundaries are:

- Default model requests use a loopback endpoint. Remote requests require explicit host and network authorization and HTTPS; redirects are rejected.
- Model sessions have an empty tool list and do not load the user's Pi configuration, skills, or extensions.
- API keys are referenced by a configured environment-variable name, not stored as `apiKey` or `api_key` in model configuration.
- State and configuration use local file permissions. They are not encrypted by the app; the process is not an operating-system sandbox for untrusted code.
- Content-storage switches and credential redaction apply to persisted state, not to live model requests or every kind of sensitive text.

See [configuration](docs/configuration.md) for exact storage behavior and [architecture](docs/architecture.md) for data flow. A model service, its dependencies, and the operating system remain separate trust boundaries. Build-time dependency downloads are outside the model network policy.

## Report a vulnerability

Contact the maintainer through an existing private channel. A dedicated GitHub private-reporting route has not been established in this documentation; do not assume that an advisory form is available. If you do not have a private route, request one without disclosing the vulnerability or sensitive data.

Do not publish exploit details, credentials, personal data, or unredacted state files in an Issue, pull request, or discussion, even when the repository is private.

Provide the affected commit or version, impact, minimal reproduction, macOS/Node versions, and the relevant sanitized settings. Use synthetic data where possible. Rotate or revoke any credential that may already have been exposed. Coordinate disclosure with the maintainer after a fix or mitigation can be assessed.

## Development artifacts

Packaged apps currently use ad-hoc signing. A successful build or signature check is not Developer ID signing, notarization, or a guarantee that another Mac will accept the app. Distribution status and validation steps are in [packaging](docs/releasing.md).
