# Output, exit codes and sync

Every command except `mcp` accepts `--json` for data. Help and errors always remain text.
`abdy version` and `abdy --version` print the release version. `abdy version --json` returns its name and version.
Invalid commands return a nonzero exit code and a help hint. Synchronization failures do not hide saved local changes.

| Default stdout | Commands |
| --- | --- |
| Note UUIDs, 1 per line | `search`, `ls`, note writes, import |
| Note blocks separated by `---` | `search --show`, `ls --show` |
| Folder UUIDs, paths and counts | `folders`, `stats` |
| Affected folder UUID | Folder writes |
| Saved paths | Attachment export, snapshots |
| Requested text or fields | Readers and status commands |

No matches produce empty search stdout. Text search reports returned and total matches in stderr, including zero results.
Text lists report their note count in stderr. Saved actions report their action and destination there.
JSON actions include `action`, `saved` and the affected object's data. Folder creation includes its initial counts.
`saved` means saved locally. Exit code 0 of a write confirms the local save, exit code 0 of `sync` confirms iCloud acknowledgement. Use `inspect` or `sync --status` for current cloud status.
Progress and errors use stderr. JSON import returns `notes` and `summary`.

Before writes, the CLI closes Notes normally. Do not open Notes or run another writer during a write.
If database access is denied, check the calling application's Full Disk Access.
`sync` waits for iCloud acknowledgement and gives up after 120 seconds without progress, then rechecks the queue after Notes exits.
Many queued changes sync in 1 run. Readers and `sync --status` do not launch or close Notes. `open` explicitly launches Notes.
Acknowledgement is not proof that another device has displayed the change.

Snapshots include database records and committed WAL data, but not attachment files.
They are not complete backups. Never restore a snapshot over a live iCloud database.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done. For a Notes write: saved locally. For `notes sync`: iCloud acknowledged. For Reminders and Calendar writes: saved and handed to macOS sync |
| 1 | Data or environment error: not found, read-only, refused, access denied, sync timeout. stderr has the reason |
| 64 | Invalid arguments. stderr has the usage hint |

## References

Every reference that `abdy` prints is accepted as input.
Notes: UUID, unique prefix of 8 characters or `applenotes://` URL. Folders: name, path, UUID or prefix. Attachments: file name, UUID or prefix. Tags: name with or without `#`.
Reminders and events: UUID or prefix. Lists and calendars: name, UUID or prefix. Sources: name or id.
Prefixes shorter than 8 characters and ambiguous names are refused with the candidates listed.
