#!/usr/bin/env bash
set -euo pipefail

repo="rwa-tokenization3643/institutional-rwa-platform"
issue_file=".github/issue-backlog.json"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to create GitHub issues." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to read ${issue_file}." >&2
  exit 1
fi

node -e '
const fs = require("fs");
const issues = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const issue of issues) {
  console.log(JSON.stringify(issue));
}
' "${issue_file}" | while IFS= read -r issue; do
  title="$(node -e 'const issue = JSON.parse(process.argv[1]); process.stdout.write(issue.title);' "${issue}")"
  body="$(node -e 'const issue = JSON.parse(process.argv[1]); process.stdout.write(issue.body);' "${issue}")"
  labels="$(node -e 'const issue = JSON.parse(process.argv[1]); process.stdout.write(issue.labels.join(","));' "${issue}")"

  gh issue create \
    --repo "${repo}" \
    --title "${title}" \
    --body "${body}" \
    --label "${labels}"
done
