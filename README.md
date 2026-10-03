# notes-buddy

A macOS command-line tool for reading, searching, editing, and organizing Apple Notes.
Built for terminal workflows and AI agents, with structured output and command-level help.

Use the Notes account already signed in on the Mac running the command.
No separate login, AppleScript, UI scripting, Shortcuts, or App Intents are required.

> This project uses private Apple APIs. Test it on disposable notes before using important data.
> Every saved write automatically waits for iCloud acknowledgement.
> Notes briefly runs in the background, then exits without opening windows or taking focus.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Command reference](#command-reference)
- [Search](#search)
- [Editing and formatting](#editing-and-formatting)
- [Attachments](#attachments)
- [Tags and links](#tags-and-links)
- [Folders](#folders)
- [Bear import](#bear-import)
- [Synchronization and safety](#synchronization-and-safety)
- [Output for agents](#output-for-agents)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Release status](#release-status)
- [License](#license)

## Features

| Area | Capabilities |
| --- | --- |
| Reading | List notes and folders, read plain text or HTML, inspect native objects as JSON |
| Search | Partial words, phrases, fuzzy matches, IDs, titles, text, table cells, tags, links, and filenames |
| Documents | PDF text, scanned PDF pages, image OCR, and existing Notes text indexes |
| Editing | Replace or insert visible text while preserving native objects and formatting |
| Formatting | Inline styles, headings, lists, and checked or unchecked checklist items |
| Tables | Create from CSV or dimensions, edit cells, add or remove rows and columns |
| Files | Add, export, replace, move, remove, and change attachment display size |
| Organization | Nested folders, note moves, native tags, and links between notes |
| Import | Bear notes, files, images, tags, folder paths, and cross-references |
| Synchronization | Automatic iCloud acknowledgement after saved changes, without an opt-in flag |

## Requirements

| Requirement | Details |
| --- | --- |
| Operating system | macOS with Apple Notes and its installed private frameworks |
| Verified environment | macOS 27.0.1, Apple Silicon, Apple Swift 6.4 |
| Package manifest | Swift tools version 5.9, macOS 13 deployment target |
| Source build | Xcode or Command Line Tools with Swift Package Manager |
| Account | The current macOS user's Notes data, with iCloud for synchronization |
| Database access | Full Disk Access for the calling terminal or application may be required |
| Optional import dependency | `pandoc`, used only for Bear Markdown conversion |

The deployment target is not a compatibility guarantee.
Other macOS versions, Intel Macs, and remote execution environments have not been validated.
Private APIs and document formats can change with macOS updates.

Normal note operations and document search need no external command-line utilities.
The executable still uses system frameworks and the installed Notes application.

## Installation

Source builds are currently the available installation method.

```sh
git clone https://github.com/noma4i/notes-buddy.git
cd notes-buddy
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/notes-buddy "$HOME/.local/bin/notes-buddy"
```

Add `$HOME/.local/bin` to your shell's `PATH`, or use the installed executable's full path.
Access is required while the repository remains private.

```sh
notes-buddy --help
notes-buddy help search
notes-buddy attachments --help
notes-buddy table set --help
```

Help does not read the database or launch Notes.

For Bear import, install `pandoc` separately.
Its default path is `/opt/homebrew/bin/pandoc`.
Use `--pandoc /path/to/pandoc` for another installation.

## Quick start

These commands create a disposable note.
Choose a new folder name to avoid a duplicate-folder error.

```sh
notes-buddy mkfolder "CLI Demo"
NOTE_ID=$(notes-buddy new --folder "CLI Demo" --title "Project plan")
notes-buddy insert "$NOTE_ID" --text "Draft budget"
notes-buddy edit "$NOTE_ID" --find "Draft" --with "Final"
notes-buddy tags "$NOTE_ID" --add 'project/finance,review'
notes-buddy inspect "$NOTE_ID"
notes-buddy search "finace"
```

Check each command's exit code before using its output.
A write can save locally and then fail during synchronization.
Do not blindly repeat `new` after a nonzero exit.

## Command reference

Every command supports `-h` and `--help`.
Use `notes-buddy help COMMAND` for usage and examples.
`ID` means a local note ID returned by `ls`, `search`, or `new`.
Folder references accept a name or ID, not a slash-separated path.

### Notes, folders, and search

| Command | Arguments and options | Result |
| --- | --- | --- |
| `folders` | `--json` | Folder list with IDs and optional parent IDs |
| `mkfolder` | `NAME`, `--parent NAME_OR_ID` | Create a root or nested folder, print its ID |
| `rmfolder` | `NAME_OR_ID` | Delete an empty folder without subfolders |
| `ls` | `--folder NAME_OR_ID`, `--tag TAG`, `--json` | List active notes |
| `show` | `ID`, `--html` | Plain text or Notes HTML |
| `inspect` | `ID` | Native content, objects, folder path, and cloud state as JSON |
| `search` | `QUERY`, `--field FIELD`, `--folder NAME_OR_ID`, `--limit N`, `--offset N` | Search results as JSON |
| `new` | `--folder NAME_OR_ID`, `--title TITLE`, `--html FILE` | Create a note, print its ID |
| `mv` | `ID`, `--folder NAME_OR_ID` | Move a note without changing its ID |
| `rm` | `ID` | Move a note to Recently Deleted |

### Text and formatting

| Command | Required input | Optional input |
| --- | --- | --- |
| `edit` | `ID`, `--find TEXT`, `--with TEXT` | `--all` |
| `insert` | `ID`, `--text TEXT` | `--before TEXT` or `--after TEXT` |
| `format` | `ID`, `--find TEXT`, `--style STYLE` | `--off`, `--checked`, `--all` |
| `append` | `ID`, `--html FILE` | None |
| `replace` | `ID`, `--find HTML`, `--with HTML` | `--all` |

### Tables

| Command | Required input | Optional input |
| --- | --- | --- |
| `table ls` | `ID` | `--json` |
| `table new` | `ID`, exactly one of `--csv FILE` or `--size ROWSxCOLUMNS` | None |
| `table set` | `ID`, `--row N`, `--col N`, `--value TEXT` | `--table N` |
| `table add-row` | `ID` | `--table N`, `--at N` |
| `table rm-row` | `ID`, `--row N` | `--table N` |
| `table add-col` | `ID` | `--table N`, `--at N` |
| `table rm-col` | `ID`, `--col N` | `--table N` |

Table, row, and column numbers start at 1.
`--table` defaults to 1. Without `--at`, rows and columns are appended.
The last row or column cannot be removed.

### Attachments, tags, and links

| Command | Required input | Optional input |
| --- | --- | --- |
| `attach` | `ID`, `FILE` | None |
| `attachments ls` | `ID` | None |
| `attachments export` | `ID`, `--attachment ATTACHMENT_ID`, `--file DESTINATION` | None |
| `attachments add` | `ID`, `--file FILE` | `--before TEXT` or `--after TEXT` |
| `attachments replace` | `ID`, `--attachment ATTACHMENT_ID`, `--file FILE` | None |
| `attachments mv` | `ID`, `--attachment ATTACHMENT_ID`, `--to TARGET_ID` | None |
| `attachments rm` | `ID`, `--attachment ATTACHMENT_ID` | None |
| `attachments view` | `ID`, `--attachment ATTACHMENT_ID`, `--size 0_OR_1_OR_2` | None |
| `tags` | `ID` | `--add TAGS`, `--remove TAGS` |
| `links ls` | `ID` | None |
| `links add` | `ID`, `--to TARGET_ID` | `--before TEXT` or `--after TEXT` |
| `links rm` | `ID`, `--link LINK_ID` | None |

### Import, snapshots, and synchronization

| Command | Arguments and options | Purpose |
| --- | --- | --- |
| `import-bear` | `--source DIRECTORY`, `--pandoc EXECUTABLE`, `--limit N`, `--dry-run`, `--repair-folders` | Import or validate the local Bear store |
| `snapshot-db` | `DESTINATION`, `--database SOURCE` | Copy database records with committed WAL data |
| `sync` | None | Run background synchronization and wait for acknowledgement |
| `sync --status` | `--status` | Read cloud-state counters without launching or quitting Notes |

## Search

Fuzzy matching and document contents are included by default.
No extra fuzzy or document-scanning flag is needed.

```sh
notes-buddy search "invoice"
notes-buddy search "invocie reprt"
notes-buddy search "fields were failing"
notes-buddy search "report.pdf" --field attachment
notes-buddy search "Invoice number" --field document
notes-buddy search "p123" --field id
notes-buddy search "budget" --folder "Work" --limit 20 --offset 20
```

| Option | Default | Values or meaning |
| --- | --- | --- |
| `--field` | `all` | `all`, `id`, `title`, `text`, `attachment`, `tag`, `link`, `document` |
| `--folder` | All folders | Exact folder name or local folder ID |
| `--limit` | `50` | Positive number of results per page |
| `--offset` | `0` | Nonnegative number of matches to skip |

Search ignores case, accents, repeated whitespace, tabs, and line breaks within a phrase.
Queries are partial words or phrases, not regular expressions.
Alphabetic words of at least 4 letters allow 1 insertion, deletion, replacement, or adjacent transposition.
Three-letter words allow adjacent transpositions only. Shorter words remain literal.
Numbers, punctuation, and IDs remain literal. Filename words also support fuzzy matching.
Word order is preserved. More than 1 typo in a word is not guaranteed to match.

Exact matches appear before fuzzy matches.
Within each group, notes are ordered by modification date, newest first.
`total` counts matches before pagination.

`text` includes table cells. `attachment` searches filenames. `link` searches native link labels.
`all` searches existing Notes indexes and reads local PDFs and images when needed.
An exact index match avoids repeated extraction of that file.
`document` directly reads available PDFs and runs Vision OCR on images and scanned PDF pages.
OCR runs locally and does not write results into Notes.

Unavailable files and recognition failures are reported in the result.
OCR over a large collection can take time. A folder filter narrows the work.
Protected notes are skipped and counted. Deleted notes are excluded.
A folder name filter includes all folders with that exact name. Use its ID to select one.

## Editing and formatting

Use `edit` and `insert` for visible text changes that preserve native objects.

```sh
notes-buddy edit "$NOTE_ID" --find "draft" --with "final"
notes-buddy insert "$NOTE_ID" --text "Additional details" --after "Summary"
notes-buddy format "$NOTE_ID" --find "Important" --style bold
notes-buddy format "$NOTE_ID" --find "Buy milk" --style checklist --checked
notes-buddy table new "$NOTE_ID" --size 3x2
notes-buddy table set "$NOTE_ID" --row 2 --col 1 --value "Done"
```

Edits use literal text, not fuzzy matching.
A missing or ambiguous match fails without saving. Use `--all` for every occurrence.
Anchors require exactly 1 occurrence. `--before` and `--after` cannot be combined.
Without an anchor, `insert` appends plain text.
Selections cannot cross native object markers, shown as `U+FFFC` in text output.

| Style group | Values |
| --- | --- |
| Inline | `bold`, `italic`, `underline`, `strikethrough` |
| Paragraph | `title`, `heading`, `subheading`, `body`, `monospace` |
| Lists | `bullet`, `numbered`, `checklist` |

`--off` removes an inline style. Use `--style body` to remove paragraph formatting.
Checklist items are unchecked unless `--checked` is supplied.

### HTML input

`new`, `append`, and `replace` accept HTML.
Use headings, paragraphs, inline styles, lists, and tables.
The first line becomes the note title. `--title` prepends a heading.
For `new --html` and `append --html`, `-` reads standard input.

```sh
printf '%s\n' '<p>Initial content</p>' | notes-buddy new --folder "Work" --title "Plan" --html -
notes-buddy show "$NOTE_ID" --html
```

HTML rewrites refuse native objects or checklists they could lose.
Shared and deleted notes cannot be rewritten.
HTML table rewrites can recreate table objects. Prefer native table commands.
Plain-text and HTML output do not embed attachment file bytes.

## Attachments

Get attachment IDs from `inspect` or `attachments ls`.

```sh
notes-buddy attachments ls "$NOTE_ID"
notes-buddy attachments add "$NOTE_ID" --file report.pdf --after "Summary"
notes-buddy attachments export "$NOTE_ID" --attachment "$ATTACHMENT_ID" --file saved.pdf
notes-buddy attachments replace "$NOTE_ID" --attachment "$ATTACHMENT_ID" --file updated.pdf
notes-buddy attachments mv "$NOTE_ID" --attachment "$ATTACHMENT_ID" --to "$TARGET_ID"
notes-buddy attachments view "$NOTE_ID" --attachment "$ATTACHMENT_ID" --size 1
```

Adding copies the input file. The original is not modified.
Export requires a local file and refuses an existing destination.
It does not download missing iCloud attachments.
Replacement preserves the attachment position. Moves require the same Notes account.
Removal detaches the object, not the original input file.
Export before removal if you need an independent copy.

Display sizes are the native Notes values `0`, `1`, and `2`.
Their visual effect depends on the file type.
Notes can retain unused media records. The CLI does not delete them manually.
Tables can appear in attachment listings. Use `table ls --json`, not file export, to read their cells.

## Tags and links

```sh
notes-buddy tags "$NOTE_ID" --add 'invoices/tech,review'
notes-buddy tags "$NOTE_ID"
notes-buddy ls --tag invoices --json
notes-buddy tags "$NOTE_ID" --remove review
notes-buddy links add "$NOTE_ID" --to "$TARGET_ID" --after "Summary"
notes-buddy links ls "$NOTE_ID"
notes-buddy links rm "$NOTE_ID" --link "$LINK_ID"
```

Tags are native Notes objects, not plain `#tag` text.
Slashes, commas, and whitespace split tag input into separate names.
`invoices/tech,review` creates 3 tags, not a hierarchy.
Duplicate additions do not create duplicate tags.
An invalid name rejects the whole input list before saving.
Removing a tag affects only the specified note.

Note links use the target title and open the target in Notes.
Links are one-way. Add a link in each note for a bidirectional relationship.
Removing a link does not delete its target.
`links add` creates note-to-note links, not ordinary web links.

## Folders

```sh
notes-buddy folders --json
notes-buddy mkfolder "Projects"
notes-buddy mkfolder "Receipts" --parent "Projects"
notes-buddy mv "$NOTE_ID" --folder "$FOLDER_ID"
notes-buddy inspect "$NOTE_ID"
notes-buddy rm "$NOTE_ID"
notes-buddy rmfolder "$EMPTY_FOLDER_ID"
```

`folders --json` includes `parent` for nested folders. Follow parent IDs to reconstruct paths.
Root creation requires 1 Notes account. Otherwise, specify a parent folder.
Ambiguous names fail when selecting a single folder. Use its ID instead.
Moves preserve the note ID and document.
The folder and its modification timestamp change together for iCloud conflict resolution.

`rm` moves a note to Recently Deleted, where Notes can restore it.
There is no CLI restore command.
A deleted note can be inspected by its old ID while locally available.
Empty-folder deletion refuses folders containing notes or subfolders.
To rename a note, edit its first line using an exact match.

Run batch writes sequentially against an inspected list of IDs.
Commands do not form a shared transaction or undo operation.
Stop on error and inspect earlier changes before retrying.

## Bear import

```sh
notes-buddy import-bear --dry-run
notes-buddy import-bear --limit 3
notes-buddy import-bear
notes-buddy import-bear --repair-folders
```

| Option | Default | Purpose |
| --- | --- | --- |
| `--source` | Current user's Bear Application Data directory | Select a local source store |
| `--pandoc` | `/opt/homebrew/bin/pandoc` | Markdown-to-HTML executable |
| `--limit` | All active notes | Import a positive prefix count |
| `--dry-run` | Off | Validate the inventory without changing Notes |
| `--repair-folders` | Off | Restore expected tag folder paths for existing imports |

The source database is read-only. Bear is not modified.
Archived notes are included. Trashed and permanently deleted notes are excluded.
Encrypted notes and unavailable, ambiguous, or encrypted files stop the import.

Tag paths create nested folders. The deepest tag determines the destination.
Ties use alphabetical order. Untagged notes go to `Untagged`.
Tag components become separate native Notes tags.
Files and images are copied with the note.
Each note, its tags, and files are committed together.
Bear cross-references become native links after note creation.
A limited trial can defer links to targets outside that trial.

Stable source-derived IDs make repeated imports skip existing notes without overwriting them.
Deleted imports cause an error rather than being recreated.
`--repair-folders` moves existing imports without editing their contents.
Verification checks folder paths, native tags, and file SHA-256 hashes after reopening the database.
Save JSON Lines output to preserve the Bear-to-Notes mapping.

Notes stays closed during import. Synchronization starts after the command's saved work.
The whole import is not one transaction. Earlier notes can remain saved after a later failure.

## Synchronization and safety

Operations use installed NotesShared, NotesEditor, and Core Data APIs.
The CLI does not issue SQL writes into the live Notes database or migrate its schema.

Read-only commands leave Notes running or closed as they found it.
Before writes, the CLI requests normal termination and waits up to 10 seconds.
If Notes refuses to quit, the CLI does not save.
Do not open Notes or run another writer during a write command.

After saved changes, the Apple-signed Notes application launches as `BackgroundOnly`.
The CLI requires `activationPolicy=prohibited`, without windows, a Dock icon, or foreground activation.
Notes uploads changes using its existing account permissions.
This path needs no custom CloudKit entitlements or developer signing profile.

Synchronization waits for the account's upload queue to empty, with a 120-second deadline.
Launch completion is not acknowledgement.
After acknowledgement or a wait error, the CLI requests normal termination of Notes.
SIGINT, SIGTERM, and SIGHUP during synchronization also trigger shutdown and a nonzero CLI exit.
SIGKILL or a system crash cannot guarantee cleanup.

There is no flag to bypass synchronization.
Saved partial work also triggers it if the command later fails.
A timeout leaves changes saved locally and queued, then returns an error.
Inspect the object and retry `sync`, not the creation command.

`sync --status` reads account-wide counters without launching or quitting Notes.
Other account activity can contribute to these counters.
`inspect` reports `inCloud`, `cloudAcknowledged`, and `needsCloudPush` for the note's local version.
Acknowledgement does not replace content verification or observation on another device.
Check moves and deletions separately from creation.

### Database snapshots

```sh
notes-buddy snapshot-db ./snapshot.sqlite
notes-buddy snapshot-db ./copy.sqlite --database /path/to/source.sqlite
```

Snapshots use the SQLite Backup API with a read-only source and include committed WAL data.
The destination must not exist and is readable only by its owner.
Snapshots contain records, not attachment files.
They are not a complete archive or a safe rollback of iCloud state.
Never restore a snapshot over a live Notes database.

## Output for agents

| Command group | Standard output |
| --- | --- |
| `folders`, `ls` | Tab-separated text, or JSON with `--json` |
| `show` | Plain text or HTML |
| `new`, `mkfolder` | Local object ID |
| `search`, `inspect`, native edits | JSON |
| `attachments export`, `snapshot-db` | Destination path |
| `table ls` | TSV, or JSON with `--json` |
| `import-bear` | JSON Lines records and a final summary |
| `rm`, `mv`, `rmfolder`, HTML edits | No structured success payload |

Progress and errors use stderr. Keep stderr separate from JSON stdout.
A nonzero exit does not imply that no writes occurred.
Inspect the affected object before retrying.

| Search field | Meaning |
| --- | --- |
| `notes` | Current result page |
| `total` | Matches before pagination |
| `offset`, `limit` | Pagination inputs |
| `skippedProtected` | Protected notes skipped |
| `scannedDocuments` | Files whose text was extracted during this search |
| `unavailableDocuments` | Files unavailable locally during document processing |
| `documentErrors` | Extraction errors with note ID, attachment ID, and message |

Each result includes `id`, `title`, `folder`, `matchedFields`, `excerpt`, and `matchType`.
`matchType` is `exact` or `fuzzy`.
Excerpts normalize whitespace and accents. Original note content is unchanged.

IDs are local Core Data URIs such as `x-coredata://.../ICNote/p123`.
They belong to this Mac's database. Do not reuse IDs from another computer.
Obtain attachment and link IDs from CLI output instead of constructing them.

An agent workflow:

1. Read command help.
2. Find the note with `search` or `ls`.
3. Inspect the exact ID and native objects.
4. Run 1 change and check its exit code.
5. Reopen the note with `inspect` and verify the result.
6. Run multiple writes sequentially and stop on errors.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Database access denied | Check Full Disk Access for the calling terminal or application |
| Ambiguous folder name | Select an ID from `folders --json` |
| Ambiguous text match | Choose a unique anchor, or use `--all` where supported |
| HTML rewrite refused | Use native text, formatting, or table commands |
| Cloud acknowledgement timeout | Inspect saved state, check the account, then run `sync` |
| File unavailable locally | Make it available through Notes before export or extraction |
| OCR error | Inspect `documentErrors` and the affected file |
| pandoc not found | Supply an executable path with `--pandoc` |
| Bear import stopped partway | Preserve the mapping output, inspect saved notes, then rerun |
| Private API unavailable | Stop writes and validate compatibility on that macOS version |

Do not restore a database snapshot or change system security settings to fix synchronization.

## Limitations

- Protected, shared, smart-folder, and deleted content has write restrictions.
- Note and attachment moves between accounts are not supported.
- Existing folders cannot be renamed or moved through the CLI.
- Restoring and permanently deleting notes have no commands.
- Pinning, smart-folder creation, passwords, and sharing administration have no commands.
- There is no global tag catalog or incoming-link listing command.
- Full-archive export with files is not available as 1 command.
- There is no multi-command transaction, undo command, or cloud rollback.
- Missing cloud-only files are not downloaded by export or document search.
- Text extraction covers PDFs and supported images, not every file format.
- Large document collections can require substantial extraction and OCR work.
- Only the verified environment has passed local acceptance.

## Release status

This is a pre-release project. Installation currently requires a source build.
No signed or notarized binary distribution, release tag, or broader compatibility guarantee is offered here.
The repository remains private while release preparation is in progress.

## License

A project license has not yet been selected.
Do not assume an open-source license before a `LICENSE` file is added.
