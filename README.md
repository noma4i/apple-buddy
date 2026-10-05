![Command help](assets/screenshots/help.png)

# notes-buddy

Read, search, edit and organize Apple Notes from the terminal.
The executable is named `nb`.
Uses this Mac's existing Notes account. No separate login or AppleScript.

Writes sync automatically with iCloud. Notes runs hidden during synchronization and exits afterward.

## Install

Requires macOS, Apple Notes, Homebrew and Apple's Command Line Tools.
Install from our own tap, not Homebrew Core:

```sh
brew tap noma4i/notes-buddy https://github.com/noma4i/notes-buddy.git
brew install noma4i/notes-buddy/nb
```

Homebrew builds the CLI on your Mac. Update it with:

```sh
brew update
brew upgrade noma4i/notes-buddy/nb
```

While the repository is private, your Git credentials need repository access.
With GitHub CLI, configure them using `gh auth login` and `gh auth setup-git`.
GitHub installation becomes available after the tap changes are pushed and their workflow finishes.

## Start here

```sh
nb help
nb search "invoice"
```

Search prints 1 note URL per line. For example:

```text
x-coredata://E34EE572-B6FF-45E3-9FCC-766950115D39/ICNote/p1
```

Copy a URL from your own results into the next command, inside quotes:

```sh
nb show 'x-coredata://E34EE572-B6FF-45E3-9FCC-766950115D39/ICNote/p1'
```

The URL above is fictional. Your URL will differ and works only on your Mac.
Add `--json` for structured data, or use `inspect` to read formatting, tags and files.

To try editing, create a disposable note in a new folder.
The variable `note` saves the URL returned by `new`. `"$note"` reads that saved URL in later commands.

```sh
nb mkfolder "CLI Demo"
note=$(nb new --folder "CLI Demo" --title "Project plan")
nb insert "$note" --text "Draft budget"
nb edit "$note" --find "Draft" --with "Final"
nb show "$note"
```

Check each exit code before continuing. A failed sync can leave a successful local write.
Inspect saved state and retry `sync`, not `new`.

## Commands

Put `help` immediately after any command or action. Everything after it is ignored. Help never opens the database.

```sh
nb search help
nb table set help
nb attachments export help
```

| Task | Commands |
| --- | --- |
| Read notes | `ls`, `show`, `inspect` |
| Find notes | `search` |
| Create, move, delete | `new`, `mv`, `rm` |
| Pin or unpin | `pin`, `unpin` |
| Manage folders | `folders`, `mkfolder`, `rmfolder` |
| Count notes and folders | `stats` |
| Edit visible text | `edit`, `insert` |
| Edit HTML without native objects | `append`, `replace` |
| Apply styles or checklists | `format` |
| Edit tables | `table` with `ls`, `new`, `set`, `add-row`, `rm-row`, `add-col`, `rm-col` |
| Manage files | `attachments` with `ls`, `add`, `export`, `replace`, `mv`, `rm`, `view`. `attach` also adds files |
| Manage native tags | `tags` |
| Link notes | `links` with `ls`, `add`, `rm` |
| Import Bear | `import-bear` |
| Copy database records | `snapshot-db` |
| Back up local data | `backup`, `restore` |
| Sync or check status | `sync`, `sync --status` |

Folder selectors accept a name or ID. Use IDs for ambiguous names.
Actions reject options that they do not use. For example, `attachments ls` does not accept `--file`.
Moves preserve note IDs and contents. `rm` moves notes to Recently Deleted.
`rmfolder` accepts only empty folders without subfolders.

Pin a note with `nb pin "$note"`. Remove its pin with `nb unpin "$note"`.
Repeated commands keep the requested state. Both sync automatically and preserve note contents.
Use `nb inspect "$note" --json` to read the `pinned` field.

## Folder statistics

```sh
nb stats
nb stats --folder Work --json
nb folders --json
```

Folder data includes its URL, path, active notes, deleted notes, direct subfolders and `empty`.
`stats --folder` includes descendants. Its totals sum those folders without counting a note twice.
A folder is empty only when it has no notes, deleted notes or subfolders.

## Search

Partial words, phrases, fuzzy matching, PDF text and image OCR work by default.
Search ignores case, accents and whitespace differences. Exact matches rank before fuzzy matches.
Numbers, IDs and punctuation stay literal. Deleted notes are excluded.

```sh
nb search "wekend" --field title
nb search "Invoice number" --field document
nb search "report.pdf" --field attachment
nb search "budget" --folder Work --limit 20 --offset 20
nb ls --tag invoices
```

`--field` accepts `all` (default), `id`, `title`, `text`, `tag`, `link`, `attachment` or `document`.
Text search includes table cells. Attachment search finds filenames. Document search reads PDFs and images locally.
Missing files and extraction errors are reported. OCR does not modify Notes.

## Files, tags and links

```sh
nb attachments add "$note" --file report.pdf
nb attachments ls "$note" --json
nb attachments export "$note" --directory ./saved-files
nb tags "$note" --add 'invoices/tech,review'
```

Export saves local files without changing the note. It checks the whole batch and never overwrites existing files.
Duplicate names get numeric suffixes. Tables are skipped. Disk errors can leave completed copies.
Missing iCloud files are not downloaded. Add `--attachment` to directory export to select 1 file.

Tags are native objects. Slashes, commas and whitespace split names into separate tags, not nested tags.
Links are one-way. Add a reverse link for a bidirectional relationship.
Use `links add` with your source note URL and `--to` followed by the target note URL.
For exporting 1 file, get its attachment URL from `attachments ls`, then read `attachments export help`.

Use `edit`, `insert`, `format` and native table commands to preserve attachments and links.
Text edits use literal matches. Missing or ambiguous selections fail. Table indices start at 1.
HTML rewrites refuse objects or checklists they could lose.

## Bear import

Requires `pandoc`, defaulting to `/opt/homebrew/bin/pandoc`. Override with `--pandoc`.

```sh
nb import-bear --dry-run
nb import-bear --limit 3
nb import-bear
```

Import reads Bear without modifying it. Tag paths create folders. Files, native tags and cross-references are preserved.
Repeated imports skip existing notes without overwriting them. `--repair-folders` restores their expected folder paths.
Earlier notes can remain saved if a later import fails. Keep stderr and the JSON mapping when importing.

## Output and safety

Every command accepts `--json` for data. Help and errors always remain text.

| Default stdout | Commands |
| --- | --- |
| Note URLs, 1 per line | `search`, `ls`, note writes, import |
| Folder URLs, paths and counts | `folders`, `stats` |
| Affected folder URL | Folder writes |
| Saved paths | Attachment export, snapshots |
| Requested text or fields | Readers and status commands |

No matches produce empty search stdout. Text search reports returned and total matches in stderr, including zero results.
Text lists report their note count in stderr. Saved actions report their action and destination there.
JSON actions include `action`, `saved` and the affected object's data. Folder creation includes its initial counts.
`saved` means saved locally. Exit code 0 confirms synchronization. Use `inspect` or `sync --status` for current cloud status.
Progress and errors use stderr. JSON import returns `notes` and `summary`.

Before writes, the CLI closes Notes normally. Do not open Notes or run another writer during a write.
If database access is denied, check the calling application's Full Disk Access.
Saved writes wait up to 120 seconds for iCloud acknowledgement, then recheck the queue after Notes exits.
There is no sync bypass flag. Read commands and `sync --status` do not launch or close Notes.
Acknowledgement is not proof that another device has displayed the change.

Snapshots include database records and committed WAL data, but not attachment files.
They are not complete backups. Never restore a snapshot over a live iCloud database.

## Backup and isolated restore

```sh
nb backup ./notes-backup --json
nb restore ./notes-backup --to ./restored-notes --json
```

Backup copies the local database and files, including committed WAL data. It verifies file checksums and database integrity.
Both destinations must be new directories. Their parent directories must already exist.
Missing required attachments, source changes or invalid files cause an error instead of a partial backup.
Restore verifies the archive before copying it. It never replaces your working database or changes iCloud.
Restored files stay in the chosen directory. They are not imported into Notes.
These commands do not launch or close Notes. Keychain credentials are not backed up. Locked data remains encrypted.

Unsupported: folder rename or move, cross-account moves, restore into a Notes account, permanent deletion, passwords, sharing and smart-folder administration.
Protected, shared and deleted notes have write restrictions. There is no multi-command transaction or undo.

![Fuzzy search](assets/screenshots/search.png)

<details>
<summary>More examples</summary>

![Text and JSON output](assets/screenshots/read.png)
![Sync help](assets/screenshots/sync.png)
![Pin and unpin help](assets/screenshots/pin.png)
![Folder statistics](assets/screenshots/stats.png)

</details>

## License

No project license has been selected. Do not assume an open-source license.
