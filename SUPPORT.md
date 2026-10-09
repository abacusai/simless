# Support

Start with the documentation:

- [README](README.md) covers requirements, installation, setup and commands.
- [How far to trust results](README.md#how-far-to-trust-results) covers what a pass and a failure mean.
- [Architecture](docs/architecture.md) explains how builds, slots, render hosts and hot reload work.
- [Findings](docs/findings.md) lists the macOS and Xcode behavior simless depends on, which helps when something changes after an update.

## Common problems

| Symptom | Try |
| --- | --- |
| `no team wildcard development profile` | Run any app once on "My Mac (Designed for iPad)" from Xcode with automatic signing, then run `simless up` again. |
| A host doesn't start | `simless status`; then `simless clean` and `simless up`. The slot's `install.log` path is printed on failure. |
| `live reload: off` | Run `simless agent install` and grant SimlessAgent Full Disk Access. Without it, reloads still work in warm mode. |
| A render doesn't match the simulator | Run `simless calibrate` to see which screens differ, and how. |
| Reload always does a full build | The edit touches something a patch can't trace (an extension of another type or a top-level function). The message names the declaration. |

## Open an issue

Use the [bug report form](https://github.com/abacusai/simless/issues/new?template=bug_report.yml) for a reproducible defect in the latest release. Include the `simless version` output, macOS and Xcode versions, the command you ran, and the smallest useful log excerpt.

Use the [feature request form](https://github.com/abacusai/simless/issues/new?template=feature_request.yml) for a proposal or a missing workflow.

Public issues are not a safe place for signing certificates, provisioning profiles, credentials or proprietary app code. Redact build logs before posting them.

## Other support

- Source builds and modified forks receive best-effort guidance. Include the exact commit and local changes when reporting a defect.
- Only the latest simless release receives fixes.
- Suspected vulnerabilities must follow the [private security process](SECURITY.md#report-a-vulnerability).

The project does not provide a private support inbox through GitHub. Use the public issue forms for non-sensitive, reproducible problems.
