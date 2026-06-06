# Contributing

Issues and pull requests are welcome! This is a personal sample repo
demonstrating private-link networking patterns for Azure AI Foundry.

## Reporting an issue

Open a GitHub issue with:

- The behavior you observed vs. expected
- The relevant azd env name (or "n/a") and Azure region
- Bicep, ARM, or `azd` error output if applicable
- Any redacted log output that helps reproduce the problem

## Submitting a pull request

1. Fork the repo and create a feature branch.
2. Keep changes focused — one logical change per PR.
3. Run `az bicep build infra/main.bicep` before pushing; the build must
   pass with no errors or warnings.
4. Update the relevant `.md` file(s) when behavior, params, or modules
   change. Documentation is part of the deliverable here, not an
   afterthought.
5. Open the PR with a clear description of *what* and *why*. Screenshots
   from the Foundry portal or KQL output are encouraged when relevant.

No CLA is required. By submitting a PR you agree to license your
contribution under the repository's [MIT License](LICENSE).
