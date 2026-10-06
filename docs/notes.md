# Notes

All commands below live under `abdy notes`. `nb` is an alias: `nb ls` runs `abdy notes ls`.
Put `help` after any command for every option: `abdy notes search help`.

## Try editing

To try editing, create a disposable note in a new folder.
The variable `note` saves the UUID returned by `new`. `"$note"` reads that saved ID in later commands.

```sh
abdy notes mkfolder "CLI Demo"
note=$(abdy notes new --folder "CLI Demo" --title "Project plan")
abdy notes insert "$note" --text "Draft budget"
abdy notes edit "$note" --find "Draft" --with "Final"
abdy notes show "$note"
abdy notes sync
```

Check each exit code before continuing. Writes exit 0 after the local save and print `run abdy notes sync` to stderr.
A failed `sync` keeps the local writes. Inspect saved state and retry `sync`, not `new`.

## Commands

Put `help` immediately after any command or action. Everything after it is ignored. Help never opens the database.

```sh
abdy notes search help
abdy notes table set help
abdy notes attachments export help
```

| Task | Commands |
| --- | --- |
| Check installed version | `version`, `--version` |
| Read notes | `ls`, `show`, `inspect` |
| Open in Notes | `open`, `open --window` for the note in its own window without the main window (needs Accessibility access) |
| Find notes | `search` |
| Create, move, delete | `new`, `mv`, `rm`. `mv` and `rm` take many ids or `-` for ids from stdin |
| Pin or unpin | `pin`, `unpin` |
| Manage folders | `folders`, `folders --tree`, `mkfolder`, `mvfolder`, `renamefolder`, `rmfolder`, `rmfolder --empty` |
| Count notes and folders | `stats` |
| Edit visible text | `edit`, `insert` |
| Edit HTML without native objects | `append`, `replace` |
| Apply styles or checklists | `format` |
| Edit tables | `table` with `ls`, `new`, `set`, `add-row`, `rm-row`, `add-col`, `rm-col` |
| Manage files | `attachments` with `ls`, `add`, `export`, `replace`, `mv`, `rm`, `view`. `attach` also adds files |
| Manage native tags | `tags`: list with counts, add or remove on many notes, `--rename`, remove everywhere |
| Find duplicates | `dups` |
| Link notes | `links` with `ls`, `add`, `rm` |
| Import Bear | `import-bear` |
| Copy database records | `snapshot-db` |
| Back up local data | `backup`, `restore` |
| Sync or check status | `sync`, `sync --status` |
| Connect agents | `mcp`, see [mcp.md](mcp.md) |

Every reference that `abdy` prints is accepted as input.
A note is selected by UUID, unique prefix or its `applenotes://` URL.
A folder is selected by UUID, unique prefix, path such as `Work/Project` or name. Names and paths ignore case.
An exact path wins over a name. Use a path or UUID when several folders share a name.
An attachment is selected by UUID, unique prefix or file name. A tag is written with or without `#`.
Actions reject options that they do not use. For example, `attachments ls` does not accept `--file`.
Moves preserve note IDs and contents. `rm` moves notes to Recently Deleted.

## Bulk changes

```sh
abdy notes ls --folder Inbox | abdy notes mv - --folder Archive
abdy notes rm <id> <id>
abdy notes mvfolder Work/Old --parent Archive
abdy notes renamefolder Archive/Old --name "Old projects"
abdy notes rmfolder Archive --empty
abdy notes tags
abdy notes tags <id> <id> --add review
abdy notes tags --remove draft
abdy notes tags --rename draft --to review
abdy notes dups --folder Work
abdy notes folders --tree
abdy notes ls --folder Work --long --no-recursive
```

A batch is checked before any change and saved once: 1 refusal cancels the whole batch.
`rmfolder --empty` deletes every folder of the subtree without notes, deepest first, and keeps folders with notes.
`tags` without ids lists every tag with its note count. `tags --remove` without ids takes the tag off every note.
`dups` groups notes with identical text, table cells included, and identical attachment files by SHA-256.
`folders --json` has `totalNoteCount`, `totalDeletedNoteCount` and `parentPath` next to the direct counts.
`ls --long` prints `uuid`, `modified`, `folderPath` and `title` separated by tabs. `--no-recursive` reads 1 folder without its subfolders in `ls`, `search` and `stats`.
`backup --skip-missing` backs up without attachments that have no local file and lists them in stderr, in `skippedAttachments` and in the manifest.
`sync` reports `sentObjects` and `seconds`, and prints `Sent N objects in T s` to stderr.
`rmfolder` accepts only empty folders without subfolders.

Pin a note with `abdy notes pin "$note"`. Remove its pin with `abdy notes unpin "$note"`.
Both commands read the pin again after synchronization. If iCloud overwrote it, they write it again up to 3 times, then return an error.
Repeated commands keep the requested state. Both sync on their own, the pin state lives in iCloud, and preserve note contents.
Use `abdy notes inspect "$note" --json` to read the `pinned` field.

## Folder statistics

```sh
abdy notes stats
abdy notes stats --folder Work --json
abdy notes folders --json
```

Folder data includes its UUID, path, active notes, deleted notes, direct subfolders and `empty`.
`--folder` in `stats`, `ls` and `search` includes subfolders. Counts of 1 folder are direct.
`stats` totals sum the listed folders without counting a note twice. In JSON they are `totalNoteCount` and `totalDeletedNoteCount`.
`ls`, `search` and `stats` read the same set of notes. Notes that iCloud has not downloaded yet are left out.
Deleted notes are listed only by `abdy notes ls --folder "Recently Deleted"`.
A folder is empty only when it has no notes, deleted notes or subfolders.

## Search

Partial words, phrases, fuzzy matching, PDF text and image OCR work by default.
Search ignores case, accents and whitespace differences. Exact matches rank before fuzzy matches.
Numbers, IDs and punctuation stay literal. Deleted notes are excluded.
Locked notes are listed by `ls` but not searched. `search` prints their number to stderr and returns it as `skippedProtected`.

```sh
abdy notes search "wekend" --field title
abdy notes search "Invoice number" --field document
abdy notes search "report.pdf" --field attachment
abdy notes search "budget" --folder Work --limit 20 --offset 20
abdy notes search invoice --show --limit 5
abdy notes ls --folder Work --show --chars 2000 --json
abdy notes ls --tag invoices
```

`--show` in `search` and `ls` prints each note in full in 1 call: UUID, title, folder, date, matched fields and the `show` text.
With `--json`, `--show` adds the `show` fields without `runs`: `text`, `textLength`, `tables`, `links` and cloud state.
`--chars N` keeps the first N characters of each text, `textLength` keeps the full length. `ls` pages with `--limit` and `--offset`.

`--field` accepts `all` (default), `id`, `title`, `text`, `tag`, `link`, `url`, `attachment` or `document`.
`link` finds links between notes, `url` finds web addresses. `id` matches exactly. `ls --tag` matches the exact tag, `--field tag` is fuzzy.
Text search includes table cells. Attachment search finds filenames. Document search reads PDFs and images locally.
Up to 4 files are indexed in parallel. Later searches reuse extracted text until a file changes.
The private index lives in `~/Library/Caches/apple-buddy/documents-v1`. Search never launches Notes or changes its database.
JSON includes `scannedDocuments`, `cachedDocuments` and document errors. Images of 2 pixels or less have no searchable text.
Missing files and extraction errors are reported. OCR does not modify Notes.
Malformed PDFs can produce a macOS decoding warning during first indexing.
`ls --json`, `search --json`, `show --json` and `inspect --json` describe a note with the same fields:
`id`, `url`, `title`, `folder`, `folderPath`, `modified`, `pinned`, `protected`, `shared`, `tags`, `attachments` and `urls`.
`shared` notes (iCloud collaboration) and `protected` notes cannot be changed by `abdy`. A refusal names the note, its state and the action, for example `Note <UUID> is shared and cannot be moved`.
`folder` contains a folder UUID, `folderPath` its readable path. A field without a value is omitted.
`table ls --json` returns `{id, tables}` with the table number for `--table`.

## Files, tags and links

```sh
abdy notes attachments add "$note" --file report.pdf
abdy notes attachments ls "$note" --json
abdy notes attachments export "$note" --directory ./saved-files
abdy notes tags "$note" --add 'invoices/tech,review'
```

Export saves local files without changing the note. It checks the whole batch and never overwrites existing files.
Duplicate names get numeric suffixes. Tables are skipped. Disk errors can leave completed copies.
Missing iCloud files are not downloaded. Add `--attachment` to directory export to select 1 file.
A note without files returns an error and creates no directory.

Tags are native objects. Slashes, commas and whitespace split names into separate tags, not nested tags.
Links are one-way. Add a reverse link for a bidirectional relationship.
Use `links add` with your source note ID and `--to` followed by the target note ID.
For exporting 1 file, get its UUID from `show --json` or `attachments ls`, then read `attachments export help`.
Attachment metadata includes `id`, owning `note`, `type` and `kind`. Files (`kind: file`) add `name`, `available` and `exportable`.
Locally stored files also include `path` and a `file://` URL. Native tables (`kind: table`) are not exported and appear in `tables`.
Web links appear in `urls`, with their label and address. Links between notes appear in `links`.
A link to a PDF website is not a file attachment. Export does not download web links.

Use `edit`, `insert`, `format` and native table commands to preserve attachments and links.
Text edits use literal matches. Missing or ambiguous selections fail. Table indices start at 1.
HTML rewrites refuse objects or checklists they could lose.

## Bear import

Requires `pandoc`, defaulting to `/opt/homebrew/bin/pandoc`. Override with `--pandoc`.

```sh
abdy notes import-bear --dry-run
abdy notes import-bear --limit 3
abdy notes import-bear
```

Import reads Bear without modifying it. Tag paths create folders. Files, native tags and cross-references are preserved.
Notes tags accept letters, digits, `_` and `-`. A Bear tag with a space or another character stops the import before any change.
Repeated imports skip existing notes without overwriting them. `--repair-folders` restores their expected folder paths.
Earlier notes can remain saved if a later import fails. Keep stderr and the JSON mapping when importing.

## Backup and isolated restore

```sh
abdy notes backup ./notes-backup --json
abdy notes restore ./notes-backup --to ./restored-notes --json
```

Backup copies the local database and files, including committed WAL data. It verifies file checksums and database integrity.
Both destinations must be new directories. Their parent directories must already exist.
Missing required attachments, source changes or invalid files cause an error instead of a partial backup.
Restore verifies the archive before copying it. It never replaces your working database or changes iCloud.
Restored files stay in the chosen directory. They are not imported into Notes.
These commands do not launch or close Notes. Keychain credentials are not backed up. Locked data remains encrypted.

Unsupported: cross-account moves, restore into a Notes account, permanent deletion, passwords, sharing and smart-folder administration.
Protected, shared and deleted notes have write restrictions. There is no multi-command transaction or undo.

Output rules, exit codes and the sync model are in [output.md](output.md).
