# Commit Message Guidelines

Clover maintainers require high-quality commit messages. Substandard
messages noticed during review are grounds for rejection.

## Why this matters

Writing low-quality commit messages destroys the utility of `git blame`.
When the history fails to provide context, developers stop consulting
it. This creates a cycle of neglect: contributors stop writing detailed
messages because they assume the history is unread and unvalued.

This is critical for us because Clover uses commit messages, rather than
comments, to record the thinking behind code. In this regard, we follow
the tradition of the Linux kernel. Comments remain valuable, but they
should be concise and timeless, relying on commit messages to handle
historical context.

Therefore, you must have easy access to `git blame` in your editor or be
familiar with tools that trace the source of lines. If you do not have a
workflow that makes reading `blame` easy, you will miss important
context.

## The Short Version

Here is an example of a commit message for adding this document, with
annotations:

```text
Document the commit message rules for Clover                       | Subject: ~50 chars, imperative mood

The motivation and guidelines for commit messages have never been  | Body: Hard-wrapped at 72 chars
written for this project before, leading to confusion. We now have |
enough contributors that a formal treatment is necessary.          |
```

## Grammar and Formatting

The blog post
["How to Write a Git Commit Message"](https://cbea.ms/git-commit/) by
Chris Beams accurately describes the standards used by projects that
follow the Linux example, including ours.

Our specific rules are condensed below:

### The Subject Line

- **Imperative mood:** Write the subject as a command (e.g., "Add
  feature," not "Added feature").
- **Capitalization:** Capitalize the first letter.
- **Length:** Aim for 50 characters. This is the most flexible rule, but
  be concise.
- **No Prefixes:** Do not use `(feat)` or `(chore)` markers. We do not
  use these to generate release notes, so they waste space.
- **Colon Prefixes:** It is *occasionally* acceptable to use a
  colon-delimited prefix (e.g., `postgres:`) if it helps keep the
  subject short. However, avoid this unless necessary for brevity.
  Unlike Linux, we lack the naming conventions required to make
  `git log --grep` filtering on the prefix effective.

### The Body

- **Content:** The body must convey **why** and **what**. The "how" is
  less important. Unless the implementation is extremely subtle, the
  diff is enough.
- **Wrapping:** Hard-wrap text to roughly 72 characters. Configure your
  editor to do this automatically. Do not insert line breaks manually,
  as the poorly flowing paragraphs in the terminal will annoy readers.
- **Markdown:** Markdown is acceptable but not required. It is useful
  for single-patch Pull Requests, as GitHub renders the commit body as
  the PR description.

### References

- **Use Hashes:** Do not link to Pull Request URLs when a commit hash
  suffices. Hashes can be resolved locally; URLs require a browser.
- **External Links:** When referencing an issue or PR, use the full URL
  so it is clickable in terminal emulators.

## Example Commit Messages

Compared to Linux or Postgres, we include less metadata, but we follow
similar rules otherwise.

**Examples from Linux:**

- **Adding a feature:**
  https://github.com/torvalds/linux/commit/620a50c927004f5c9420a7ca9b1a55673dbf3941
- **A cleanup (short message):** Not every change justifies a novel.
  https://github.com/torvalds/linux/commit/ab0347e67dacd121eedc2d3a6ee6484e5ccca43d
- **A small adjustment (long message):** Often, small changes require a
  detailed explanation of why the original implementation was wrong.
  https://github.com/torvalds/linux/commit/6fc0a7c99e973a50018c8b4be34914a1b5c7b383
- **Quoted output:** Including output logs is appreciated when
  applicable.
  https://github.com/torvalds/linux/commit/b5e51ef787660bffe9cd059e7abe32f3b1667a98

**Examples from Postgres:**

- https://github.com/postgres/postgres/commit/b47c50e5667b489bec3affb55ecdf4e9c306ca2d
- https://github.com/postgres/postgres/commit/5b4fb2b97d2d953629f2a83adb6b7292b4745476
- https://github.com/postgres/postgres/commit/84d5efa7e3ebcf04694d312b0f14ceb35dcdfb8e
