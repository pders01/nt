# nt

A self-contained, agent-friendly markdown filesystem store, in a
single Perl script.

`nt` treats the filesystem as the database. Records are plain
markdown files organized into namespaces (subdirectories) under
`~/.nt/`. The CLI is TTY-aware: it opens `$EDITOR` for humans, reads
stdin in pipelines, and emits JSON when stdout is not a terminal.

## Why

- **Plain files, plain markdown.** Records are `.md` files you can
  `cp`, `grep`, `git`, or open in any editor. No database, no
  proprietary format.
- **Round-trip integrity.** Markdown without frontmatter stays
  byte-identical. Frontmatter the parser doesn't understand is
  preserved verbatim, so arbitrary YAML survives a write cycle.
- **Agents and pipelines first-class.** Stable exit codes,
  stdout/stderr discipline, auto-JSON in non-interactive contexts.
- **No external CLI dependencies.** Pure Perl. No `gum`, no `glow`,
  no editor plugins.

## Install

```sh
cpan Path::Tiny Readonly
chmod +x nt.pl
mv nt.pl ~/bin/nt   # or anywhere on $PATH
```

`Carp`, `English`, `Getopt::Long`, `JSON::PP`, and `Pod::Usage` are
core. `Path::Tiny` and `Readonly` are the only non-core dependencies.

## Quickstart

```sh
nt init                              # create ~/.nt
echo "# Hello" | nt add greetings/hi # create from stdin
nt list                              # list keys
nt view greetings/hi                 # print the record
nt edit greetings/hi                 # open in $EDITOR
nt delete greetings/hi
```

## Concepts

A **record** is a markdown file at `$base/$namespace/$name.md`. The
**key** is the relative path without the `.md` extension —
`work/projects/kafka` lives at `~/.nt/work/projects/kafka.md`.

A **namespace** is just a subdirectory. Records can live at the root
(no namespace prefix) or nested arbitrarily deep.

**Frontmatter** is optional, Jekyll/Hugo-style YAML between two
`---` lines at the top of the file. Records without frontmatter are
the default — `nt` never injects metadata you didn't ask for.

## Commands

| Command | Description |
|---|---|
| `nt init` | Create the base directory |
| `nt list [ns]` | Print record keys (optionally scoped) |
| `nt view <key>` | Print a record (full / `--meta` / `--body`) |
| `nt add <key>` | Strict-create (fails if exists) |
| `nt put <key>` | Upsert |
| `nt edit <key>` | Open existing record in `$EDITOR` |
| `nt delete <key>` | Remove a record |
| `nt find <pattern>` | Print keys whose body or meta matches |
| `nt usage` | Print a short overview (add `-v` for full help) |

## Options

| Flag | Effect |
|---|---|
| `-b`, `--base_directory DIR` | Base directory (default `$HOME/.nt`) |
| `--json` / `--no-json` | Force or suppress JSON output |
| `--meta` | For `view`: emit only the frontmatter |
| `--body` | For `view`: emit only the body |
| `-m`, `--set k=v` | For `add`/`put`: set a frontmatter key (repeatable) |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Generic error |
| `2` | Usage error |
| `3` | Key not found |
| `4` | Key already exists (`add` only) |

Errors go to stderr, prefixed with `nt:`.

## Agent and pipeline usage

`nt` adapts to non-interactive contexts without flags:

```sh
# Auto-JSON when stdout is not a TTY
nt list | jq '.[]'
nt view work/todo --meta | jq '.tag'

# Read body from stdin
echo "Replacement body" | nt put work/todo

# Patch frontmatter without touching the body
nt put work/todo -m status=done -m closed_at=2026-04-28

# Round-trip a record
nt view work/todo > snapshot.md
nt put work/todo < snapshot.md   # byte-identical write

# Search and act
nt find 'TODO' | xargs -n1 nt view --body
```

The TTY-aware behavior is always:

- **stdin**: opens `$EDITOR` if a terminal; reads bytes if a pipe.
- **stdout**: human format if a terminal; JSON if a pipe or redirect.
- Both can be overridden with `--json` / `--no-json`.

## Frontmatter rules

`nt` follows the Jekyll/Hugo convention:

- Frontmatter exists only if the file's first line is exactly `---`
  *and* a closing `---` line follows somewhere in the file.
- Inside the body, `---` is always a horizontal rule, never a
  delimiter.
- The parser extracts `key: value` pairs into a hash, but also keeps
  the raw block verbatim. On write, raw is preferred — so anything
  the parser doesn't understand round-trips intact.
- Setting `-m k=v` re-serializes the frontmatter from the parsed
  hash, dropping non-key:value lines. Use stdin round-trip for
  records that contain richer YAML.

## Limitations

- The flat key:value frontmatter writer doesn't escape values
  containing newlines or unbalanced colons. Records that need richer
  YAML must be written via stdin so the raw block round-trips.
- `find` reads every record; for large stores, prefer
  `grep -lr ... ~/.nt`.

## License

Same terms as Perl itself.
