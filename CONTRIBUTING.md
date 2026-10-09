# Contributing

simless accepts community input through issues. The maintainers currently keep implementation, documentation and release responsibility within the project team, so external pull requests are not reviewed.

You may inspect, modify and distribute forks under the [Apache License 2.0](LICENSE). The files in `Templates/` are under [MIT No Attribution](LICENSES/MIT-0.txt). The policy above only describes how changes enter this repository.

## Choose the right channel

| Need | Channel |
| --- | --- |
| Reproducible defect | [Bug report](https://github.com/abacusai/simless/issues/new?template=bug_report.yml) |
| Proposal or missing workflow | [Feature request](https://github.com/abacusai/simless/issues/new?template=feature_request.yml) |
| Setup or diagnostics help | [Support](SUPPORT.md) |
| Suspected vulnerability | [Private security report](SECURITY.md#report-a-vulnerability) |

Search existing issues before opening a new one. Keep one problem per issue, and remove signing material, credentials and proprietary code.

## Bug reports

A useful report contains:

- the `simless version` output, or the source commit;
- macOS version, Xcode version and Mac model;
- the project shape (number of targets, Swift packages, UIKit or SwiftUI);
- the exact command and its output;
- expected and observed behavior; and
- for render differences, the `simless calibrate` output for the affected fixture.

## Feature requests

Describe the problem before proposing an interface. Include the current workaround, who runs into the problem, and any constraints that would change the design.

## Technical analysis

Root-cause analysis, reduced test cases and notes on macOS or Xcode behavior are welcome in an issue, and so are additions to [docs/findings.md](docs/findings.md). Verify commands and code against the current repository before posting them.

If you maintain a fork:

```sh
swift build -c release                     # the CLI
swiftc -O Agent/main.swift -o /tmp/agent   # SimlessAgent compiles standalone
python3 -I bench/bench.py bench/config.json # benchmarks (see bench/README.md)
```

An issue is still the right place to discuss a change with the maintainers. Unsolicited pull requests may be closed without review.

## Conduct

Follow the [Code of Conduct](CODE_OF_CONDUCT.md) in all project spaces. Report security problems privately under the [Security policy](SECURITY.md).
