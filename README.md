# nt

A markdown filesystem store in a single Perl script.

`nt` keeps records as UTF-8 `.md` files under `~/.nt/`. Use it to organize
notes by namespace, edit them in your preferred editor, and work with them
through shell pipelines or explicit JSON output. The files remain directly
accessible to editors, search tools, and version control.

## Install

Install the two non-core Perl dependencies and put the script on your `PATH`:

```sh
cpan Path::Tiny Readonly
mkdir -p ~/bin
cp nt.pl ~/bin/nt
chmod +x ~/bin/nt
```

Make sure `~/bin` is on your `PATH`. Set `$EDITOR` to select an editor;
`nt` defaults to `vi`.

## Quickstart

```sh
nt init                              # create ~/.nt
printf '# Hello\n' | nt add greetings/hi
nt list                              # list record keys
nt view greetings/hi                 # print the record
nt edit greetings/hi                 # edit the file in $EDITOR
nt delete greetings/hi
```

A **key** is a file path relative to the store, without the `.md` extension.
For example, `work/projects/kafka` refers to
`~/.nt/work/projects/kafka.md`.

A **namespace** is a subdirectory. Records can live at the store root or
in nested namespaces. Writes create parent directories as needed.
Keys and namespaces must be relative to the store: parent components (`..`),
absolute or drive-qualified paths, backslashes, and NUL bytes are rejected.
Symbolic links below the root are rejected for direct access and skipped by
`list` and `find`, even if their targets are inside the store. The configured
root itself may be a symbolic link. Invalid paths exit with code `1`.

Use `-b DIR` to select a different store:

```sh
nt -b ./notes list
```

## Commands

| Command | Description |
|---|---|
| `nt init` | Create the store directory |
| `nt list [namespace]` | List sorted keys, recursively within the optional namespace |
| `nt view <key>` | Print the full record, or select `--meta` or `--body` |
| `nt add <key>` | Create a record; fail if it already exists |
| `nt put <key>` | Create or update a record |
| `nt edit <key>` | Open an existing record file in `$EDITOR` |
| `nt delete <key>` | Remove a record |
| `nt find <pattern>` | List keys whose body or frontmatter matches a Perl regular expression |
| `nt usage` | Show a short overview; use `-v` for detailed help |

For `add` and `put`, piped stdin supplies the body. With interactive stdin,
`nt` opens an editor for the body unless `--set` is supplied. `edit` opens
the complete file, including any frontmatter.

## Options

| Option | Effect |
|---|---|
| `-b`, `--base_directory DIR` | Store directory; defaults to `$HOME/.nt` |
| `--json` / `--no-json` | Select JSON or text output; defaults to text |
| `--meta` | For `view`, show only frontmatter |
| `--body` | For `view`, show only the body |
| `-m`, `--set KEY=VALUE` | For `add` and `put`, set a frontmatter field; repeatable |
| `-v`, `--verbose` | For `usage`, show detailed help |

## Pipelines and JSON

Text output is the default, including in pipes and redirects:

```sh
nt list work
nt view work/todo --body > todo.md
printf 'Replacement body\n' | nt put work/todo
nt find 'TODO' | while IFS= read -r key; do nt view "$key" --body; done
```

Request JSON for agents and tools that need structured data:

```sh
nt list --json
nt view work/todo --json
nt view work/todo --meta --json
```

- `list` and `find` return arrays of keys.
- `view` returns an object with `key`, `meta`, and `body`.
- `view --meta` returns the parsed metadata object.
- `view --body` returns the body as a JSON string.

`--json` affects these read commands; successful writes produce no output.

## Frontmatter

Frontmatter is optional. To add simple metadata:

```sh
printf '# Tasks\n' | nt add work/todo -m status=open
nt put work/todo -m status=done
```

A metadata-only update leaves the body unchanged when stdin is interactive
or empty. Nonempty piped input replaces the body even when `--set` is used.

`nt` recognizes a frontmatter block at the start of a file, with opening
and closing `---` lines terminated by newlines:

```markdown
---
status: open
tag: work
---
# Tasks

- Review the proposal
```

The parser extracts simple `key: value` lines and retains the raw block.
Updates that do not use `--set` preserve existing raw frontmatter.
`--set` rebuilds the block from parsed fields in sorted order, so comments,
nested YAML, and other unparsed content are not preserved by that operation.

Piped input to `add` or `put` is treated as body text, not parsed as a full
record. To edit or replace frontmatter directly, use `nt edit` or work with
the `.md` file itself. Piping a full record back into an existing record
with frontmatter can duplicate its metadata block.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error, such as an invalid search pattern or editor failure |
| `2` | Usage error |
| `3` | Record not found |
| `4` | Record already exists (`add`) |

Command errors are written to stderr with an `nt:` prefix.

## Limitations

- Frontmatter parsing is not a full YAML implementation. The metadata writer
  does not quote or escape values; edit the file directly for richer YAML.
- `find` reads every record. For large stores, filesystem search tools such
  as `grep` or `rg` may be more suitable.
- Path checks do not protect against concurrent replacement of store entries.
  Use a store directory writable only by trusted processes.

## Tests

With the dependencies installed:

```sh
perl -c nt.pl
prove -v t
```

Tests use temporary stores and CLI subprocesses; they do not touch real notes.

## License

Same terms as Perl itself.
