---
name: jira-acli
description: >-
  Access Jira Cloud through the Atlassian CLI (`acli`). Use when the user
  mentions Jira tickets, issues, work items, JQL, projects, boards, sprints,
  filters, comments, transitions, or Jira authentication.
---

# Jira via ACLI

Use `acli jira` for Jira Cloud operations. Jira issues and tickets are called
*work items* by the CLI.

## Verify first

Never rely on remembered syntax:

```bash
command -v acli
acli --version
acli jira auth status
acli jira <entity> <action> --help
```

If authentication is missing, ask the user to authenticate:

```bash
acli jira auth login --web
```

For API-token login, use `--token` so the CLI reads the token from stdin. Never
put tokens in chat, command arguments, logs, or committed files.

## Operating rules

1. Prefer `--json` for data the agent must parse.
2. Read the current work item before editing it.
3. Treat create, edit, transition, comment, archive, and delete commands as
   mutations; run them only with explicit user consent.
4. For bulk edits or transitions, show the JQL/filter and expected scope before
   using `--yes`.
5. Use `--description-file` or `--body-file` for long content.
6. On permission or authentication errors, report the failure; do not attempt
   escalation.
7. If a command is unavailable, report `acli --version` and inspect the exact
   command's `--help`.

## Common reads

```bash
acli jira workitem view PROJ-123 \
  --fields summary,description,status,assignee --json

acli jira workitem search \
  --jql 'project = PROJ AND status = "In Progress"' \
  --limit 50 --json

acli jira workitem search --jql 'project = PROJ' --count
acli jira project list --json
acli jira sprint view --id 42 --json
acli jira sprint list-workitems --sprint 42 --board 7 --json
acli jira workitem comment list --key PROJ-123 --json
```

Use `--paginate` only when all matching work items are required. Use `--fields`
to limit payload size.

## Common writes

After obtaining explicit consent:

```bash
acli jira workitem create \
  --project PROJ --type Task --summary "Title" --json

acli jira workitem edit \
  --key PROJ-123 --description-file description.txt --yes --json

acli jira workitem transition \
  --key PROJ-123 --status Done --yes --json

acli jira workitem comment create \
  --key PROJ-123 --body-file comment.txt --json
```

Use `--generate-json` and `--from-json` for complex or custom fields. Status
names must exactly match the site's workflow.

## Failure handling

- Wrong site/account: inspect `acli jira auth status`, then use
  `acli jira auth switch --help`.
- Unknown field or custom-field failure: inspect field metadata and use the
  command's generated JSON format.
- Unknown subcommand or flag: inspect live `--help`; do not guess.
