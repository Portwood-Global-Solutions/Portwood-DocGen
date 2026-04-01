# Portwood DocGen — AppExchange Package Info

## Package Details

| Field | Value |
|-------|-------|
| Package Name | Portwood DocGen |
| Package Type | Managed 2GP |
| Namespace | portwoodglobal |
| Version | 1.13.0 |
| Subscriber Package Version ID | 04tal000006PM3VAAW |
| Package ID | 0Hoal0000003d9hCAA |
| DevHub Org ID | 00Dal00001QGGvlEAH |

## Install Links

**Production:**
https://login.salesforce.com/packaging/installPackage.apexp?p0=04tal000006PM3VAAW

**Sandbox:**
https://test.salesforce.com/packaging/installPackage.apexp?p0=04tal000006PM3VAAW

**CLI:**
```bash
sf package install --package 04tal000006PM3VAAW --wait 10 --target-org <your-org>
```

## Post-Install Setup

1. Assign **DocGen Admin** permission set to administrators
2. Assign **DocGen User** permission set to end users
3. Enable the **Blob.toPdf() Release Update** in Setup (required for PDF output)
4. Open the **DocGen** app from the App Launcher

## Pricing

Free — all features, all users, no limits. No paid tiers.

## Source Code

GitHub: https://github.com/Portwood-Global-Solutions/Portwood-DocGen
License: Apache 2.0

## Quality Metrics

| Metric | Value |
|--------|-------|
| Apex Tests | 615/615 passing |
| Code Coverage | 76% org-wide |
| E2E Tests | 24/24 passing |
| Code Analyzer Critical | 0 |
| Code Analyzer High | 0 |
| External Callouts | 0 |
| Sharing Model | All classes use `with sharing` |
| CRUD/FLS | All queries use `WITH USER_MODE` |

## Community & Support

| Channel | Link |
|---------|------|
| Community Channel (Slack) | https://portwoodglobalsolutions.com/DocGenCommunity |
| GitHub Issues | https://github.com/Portwood-Global-Solutions/Portwood-DocGen/issues |
| Website | https://portwoodglobalsolutions.com |
| Roadmap | https://portwoodglobalsolutions.com/DocGenRoadmap |
| Email | hello@portwoodglobalsolutions.com |
