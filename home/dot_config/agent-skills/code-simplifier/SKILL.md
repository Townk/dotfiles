---
name: code-simplifier
description: Simplifies and refines code for clarity, consistency, and maintainability while preserving all functionality. Use when asked to simplify code, clean up code, refactor for clarity, improve readability, or review recently modified code for elegance.
---

# Code Simplifier

Enhance code clarity, consistency, and maintainability without altering
behavior. Prefer readable, explicit code over compact or clever solutions.

## Refinement principles

### Preserve functionality

Never change what the code does, only how it does it. Keep all existing
features, outputs, and behaviors intact.

### Apply project standards

Read local guidance and nearby code before editing. Follow the conventions in
files such as `AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, package configuration,
and sibling source files.

### Enhance clarity

- Reduce unnecessary complexity and nesting.
- Eliminate redundant code and premature abstractions.
- Use clear variable and function names.
- Consolidate closely related logic.
- Remove comments that only restate obvious code.
- Avoid nested ternaries; use clear branching for multiple conditions.
- Choose clarity over brevity.

### Maintain balance

Do not:

- Combine unrelated concerns into one function or component.
- Remove abstractions that improve organization.
- Optimize for fewer lines at the expense of readability.
- Make code harder to debug or extend.

### Focus scope

Only refine code recently modified in the current session or explicitly named
by the user. Do not broaden the refactor without consent.

## Process

1. Identify the requested or recently modified scope.
2. Read project guidance and two or three nearby siblings.
3. Find concrete opportunities to improve clarity and consistency.
4. Make the smallest behavior-preserving changes.
5. Run the relevant verification.
6. Summarize only changes that materially affect understanding.

## Examples

### Replace nested ternaries with clear branching

```typescript
function getStatus(
  isLoading: boolean,
  hasError: boolean,
  isComplete: boolean,
): string {
  if (isLoading) return "loading";
  if (hasError) return "error";
  if (isComplete) return "complete";
  return "idle";
}
```

### Name intermediate values when they clarify intent

```typescript
const positiveNumbers = values.filter((value) => value > 0);
const doubled = positiveNumbers.map((value) => value * 2);
const sum = doubled.reduce((total, value) => total + value, 0);
```

### Prefer a direct check over a single-use wrapper

```typescript
if (items.length > 0) {
  // ...
}
```
