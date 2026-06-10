---
name: release-notes-style
description: The house format for release notes. Use this whenever you are asked to write or tidy release notes. It sets the headline rule, the grouping order, and where upgrade notes go.
---

# Release-notes house style

Follow this format every time you write release notes. It keeps releases
scannable and comparable across versions.

## Format

- Open with a single bold one-line headline naming the release and its theme,
  no more than 20 words.
- Group changes under three headings, in this order: `New`, `Changed`, `Fixed`.
  Omit a heading with no entries.
- Each entry is one sentence, starts with a capital letter, and has no trailing
  period. Lead with the component name when there is one.
- Breaking changes go at the TOP of `Changed`, each prefixed with
  `Breaking:`.
- End with an `Upgrade notes:` section, even if it only says
  `Upgrade notes: none`.

## Example shape

**v1.4 tightens policy enforcement and halves cold-start time**

New
- Registry policies can now name individual tools

Changed
- Breaking: the default role claim is now `groups`

Fixed
- Catalog list no longer times out on cold start

Upgrade notes: re-run the role-mapping step before upgrading the controller
