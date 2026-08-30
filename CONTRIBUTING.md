# Contributing

Thanks for taking the time to improve this project.

This is a personal Open Source project, maintained primarily for the author's
own infrastructure. Contributions are welcome when they improve security,
correctness, clarity, or reproducibility without making the core harder to
understand. Issues and pull requests are reviewed on a best-effort basis.

There is no guaranteed response SLA, public roadmap, or commitment to
implement feature requests, backport changes, or support every deployment
environment. Small, focused changes are the easiest to review.

## Before opening a pull request

1. Search existing issues and pull requests.
2. For a substantial design or feature change, open an issue first.
3. Keep the change focused and update the relevant documentation and tests.
4. Do not include credentials, private host details, generated evidence, or
   other private planning artifacts.

## Local checks

Set up the development environment with:

```sh
./scripts/bootstrap.sh
```

Run the fast checks before submitting a pull request:

```sh
./scripts/check.sh
```

If your change affects the deployment or release paths, also run the relevant
extended checks described by `./scripts/check.sh --help`.

## Pull requests

Pull requests should explain the problem, the chosen approach, and how the
change was tested. Include security and operational impact when applicable.

The maintainer may request changes, defer a contribution, or close it when it
does not fit the project's scope or minimal design. A pull request is not an
agreement to provide ongoing support for the resulting configuration.

By submitting a contribution, you confirm that you have the right to submit
it under the repository's [MIT License](LICENSE).
