# Documentation project instructions

## About this project

- This is the documentation site for **Gust**, a statically typed, compiled language that transpiles to C (`.g` source → C → native binary via GCC). The compiler is self-hosted.
- Built on [Mintlify](https://mintlify.com). Pages are MDX files with YAML frontmatter.
- Configuration and navigation live in `docs.json`.
- Run `mint dev` to preview locally.
- Run `mint broken-links` to check links.

## Terminology

- The integer type is spelled `integer` (never `int` or `i64`).
- Every block closes with a bare `end` — never `endif`, `end def`, or a brace.
- Concurrency is opt-in via the `!` suffix: `def!`, `for!`, `while!`. Plain forms are sequential.
- "Standard library package", not "module". Import with `use <pkg>`.
- Code fences for Gust use the `gust` language tag.

## Style preferences

- Use active voice and second person ("you").
- Keep sentences concise — one idea per sentence.
- Use sentence case for headings.
- Bold for UI elements: Click **Settings**.
- Code formatting for file names, commands, paths, keywords, and code references.
- Every page needs frontmatter with `title` and `description`.
- Internal links are root-absolute and omit the file extension (e.g. `/lang/types`, not `lang/types.mdx`).

## Content boundaries

- Document the language, standard library, and tooling as a user of Gust experiences them.
- Compiler internals belong under `compiler/`; don't leak them into language/stdlib pages.
