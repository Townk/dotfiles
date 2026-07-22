---
name: confluence-acli
description: >-
  Access Confluence Cloud through the Atlassian CLI (`acli`). Use when the user
  mentions Confluence pages, spaces, blogs, page IDs, storage-format content,
  or Confluence authentication.
---

# Confluence via ACLI

Use `acli confluence` for Confluence Cloud operations.

## Verify first

Never rely on remembered syntax:

```bash
command -v acli
acli --version
acli confluence auth status
acli confluence <entity> <action> --help
```

If authentication is missing, ask the user to authenticate:

```bash
acli confluence auth login --web
```

For API-token login, use `--token` so the CLI reads the token from stdin. Never
put tokens in chat, command arguments, logs, or committed files.

## Operating rules

1. Prefer `--json` for data the agent must parse.
2. Read existing content and metadata before modifying related resources.
3. Treat blog/space creation and updates as mutations; run them only with
   explicit user consent.
4. Use files for long content and Confluence storage-format XHTML.
5. On permission or authentication errors, report the failure; do not attempt
   escalation.
6. If ACLI lacks the requested operation, say so and identify the required
   fallback instead of inventing a command.
7. If a command is unavailable, report `acli --version` and inspect the exact
   command's `--help`.

## Spaces

```bash
acli confluence space list --json
acli confluence space list --keys ENG,DOCS --expand homepage --json
acli confluence space view --id 123456 --json
```

Use the homepage metadata from a space listing to locate its root page.

## Pages

```bash
acli confluence page view --id 123456789 --json
acli confluence page view --id 123456789 --body-format storage
```

Body representations include `storage`, `atlas_doc_format`, and `view`; verify
accepted values with live `--help`.

In ACLI 1.3.22, `acli confluence page` exposes only `view`. Page search, create,
and edit therefore require another supported interface, such as the Confluence
REST API or UI. Recheck `acli confluence page --help` before choosing a
fallback because later versions may add commands.

## Blogs

```bash
acli confluence blog list \
  --space-id 12345 --title "Release Notes" --json

acli confluence blog view \
  --id 98765 --body-format storage --json
```

After obtaining explicit consent:

```bash
acli confluence blog create \
  --space-id 12345 \
  --title "Release Notes" \
  --from-file release-notes.html \
  --json
```

Blog bodies use Confluence storage-format XHTML. Use `--generate-json` and
`--from-json` for complex payloads.

## Failure handling

- Wrong site/account: inspect `acli confluence auth status`, then use
  `acli confluence auth switch --help`.
- Missing page command: verify `acli confluence page --help`, then explain the
  fallback needed.
- Unknown subcommand or flag: inspect live `--help`; do not guess.
