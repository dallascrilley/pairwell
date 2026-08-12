# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/dallascrilley/pairwell/security/advisories/new),
or by email to dallas@dallascrilley.com. Please do not open a public issue for
a security problem.

Include the affected commit, what you believe the impact is, and steps to
reproduce it. I aim to acknowledge within seven days and to say whether the
report is accepted, with a rough timeline for a fix.

## Supported versions

This project is pre-1.0 and single-branch. Only `main` receives security fixes.

## What this repository is

Pairwell is a SQL extract: PostgreSQL fuzzy matching for public filing data.
Demo data is public Texas open data plus synthetic permits. No production
client CSVs or employer systems are included.

## Credentials

Never commit tokens, API keys, or real client data. Examples and fixtures in
this repository are synthetic or public-domain samples only.
