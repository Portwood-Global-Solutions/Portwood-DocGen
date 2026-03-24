# DocGen Release Checklist

When the user asks to test, package, or release, follow this checklist in order.

## 1. Deploy to scratch org
```bash
sf project deploy start --target-org docgen-fresh --wait 10
```

## 2. Run E2E tests
```bash
sf apex run --target-org docgen-fresh -f scripts/e2e-test.apex
```
Look for: `PASS: 19  FAIL: 0  ALL TESTS PASSED`

## 3. Run Apex unit tests with coverage
```bash
sf apex run test --target-org docgen-fresh --code-coverage --result-format human --wait 15
```
Requirements: 100% pass rate, org-wide coverage >= 75%

## 4. Run Salesforce Code Analyzer
```bash
sf code-analyzer run --workspace force-app
```
Requirements: **0 Critical, 0 High, 0 Medium**. Low and Info are acceptable.

## 5. Update version
In `sfdx-project.json`, bump `versionNumber` and `versionName`.

## 6. Update README.md
- Version badge: `[![Version](https://img.shields.io/badge/version-X.Y.Z.W_Beacon-blue.svg)](#install)`
- Install links: replace old package ID with new one (after packaging)

## 7. Update CHANGELOG.md
Add new version entry at the top with bullet points for each change.

## 8. Commit
```bash
git add <changed files>
git commit -m "release: vX.Y.Z.W 'Beacon' - <summary>"
git push origin main
```

## 9. Create package version
```bash
sf package version create --package "Document Generation" --installation-key-bypass --wait 20 --code-coverage --target-dev-hub namespace-org --json
```
The package ID (SubscriberPackageVersionId starting with `04t`) will be in the JSON output.

## 10. Update install links with new package ID
Update README.md with the new `04t` ID, commit and push:
```bash
git commit -m "chore: update install links to vX.Y.Z.W package (04tXXX)"
git push origin main
```

## 11. Create GitHub release
```bash
gh release create vX.Y.Z.W --title "vX.Y.Z.W — Beacon" --notes "..."
```
Include: summary of changes, quality metrics, install command and links.

## 12. Install in scratch org
```bash
sf package install --package 04tXXX --target-org docgen-fresh --wait 10 --no-prompt
```
