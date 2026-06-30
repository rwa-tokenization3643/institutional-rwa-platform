#!/usr/bin/env bash
set -euo pipefail

repo="rwa-tokenization3643/institutional-rwa-platform"
labels_file=".github/labels.yml"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to sync GitHub labels." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to read ${labels_file}." >&2
  exit 1
fi

node - "${labels_file}" <<'NODE' | while IFS=$'\t' read -r name color description; do
const fs = require("fs");
const input = fs.readFileSync(process.argv[2], "utf8");
const entries = [];
let current = null;

for (const rawLine of input.split(/\r?\n/)) {
  const line = rawLine.trim();

  if (!line) {
    continue;
  }

  if (line.startsWith("- name:")) {
    if (current) {
      entries.push(current);
    }
    current = { name: line.slice("- name:".length).trim().replace(/^"|"$/g, "") };
    continue;
  }

  if (!current) {
    continue;
  }

  const separator = line.indexOf(":");
  if (separator === -1) {
    continue;
  }

  const key = line.slice(0, separator).trim();
  const value = line.slice(separator + 1).trim().replace(/^"|"$/g, "");
  current[key] = value;
}

if (current) {
  entries.push(current);
}

for (const entry of entries) {
  console.log([entry.name, entry.color, entry.description || ""].join("\t"));
}
NODE
  if gh label view "${name}" --repo "${repo}" >/dev/null 2>&1; then
    gh label edit "${name}" \
      --repo "${repo}" \
      --color "${color}" \
      --description "${description}"
  else
    gh label create "${name}" \
      --repo "${repo}" \
      --color "${color}" \
      --description "${description}"
  fi
done
