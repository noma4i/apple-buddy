![Command help](assets/screenshots/help.png)

# apple-buddy

Read, search, edit and organize Apple Notes, Reminders and Calendar from the terminal, for people and for AI agents.
The executable is `abdy` with 3 groups: `abdy notes`, `abdy reminders` and `abdy calendar`. `nb` is an alias for `abdy notes`.
Uses this Mac's existing accounts: iCloud, Google, Exchange, subscriptions. No separate login or AppleScript.

## Install

```sh
brew tap noma4i/apple-buddy https://github.com/noma4i/apple-buddy.git
brew install noma4i/apple-buddy/abdy
```

Requires macOS 14 or newer, Homebrew and Apple's Command Line Tools. Homebrew builds `abdy` on your Mac.
Update with `brew update && brew upgrade noma4i/apple-buddy/abdy`. Details and private-repository notes: [docs/install.md](docs/install.md).

## Quick start

```sh
abdy notes search invoice --show --limit 3
note=$(abdy notes new --folder Work --title "Project plan")
abdy notes insert "$note" --text "Draft budget"
abdy notes sync
abdy reminders add "Buy milk" --list Groceries --due 2026-10-07T18:00 --alarm 30
abdy calendar events --from 2026-10-06 --to 2026-10-13 --long
abdy mcp
```

Put `help` after any command: `abdy notes search help`. Every command accepts `--json`.
Notes writes save locally and return at once, `abdy notes sync` sends them to iCloud. Reminders and Calendar writes are saved by macOS at once.

## Documentation

| Topic | Document |
| --- | --- |
| Notes: commands, search, folders, tags, files, bulk changes, Bear import, backup | [docs/notes.md](docs/notes.md) |
| Reminders and Calendar: lists, calendars, events, repeats, access | [docs/reminders-calendar.md](docs/reminders-calendar.md) |
| MCP server: tools, results, agent workflow | [docs/mcp.md](docs/mcp.md) |
| Output formats, exit codes, references, sync model | [docs/output.md](docs/output.md) |
| Install, update, private repository access | [docs/install.md](docs/install.md) |

## Limits

Protected and shared notes are read, not changed. `notes rm` moves to Recently Deleted, Reminders and Calendar `rm` delete for good.
Read-only calendars such as subscriptions and holidays refuse writes. Attendees are shown, not invited.
Unsupported: cross-account moves, restore into a Notes account, permanent deletion of notes, passwords, sharing and smart folders.
Private Notes API compatibility is verified on macOS 27 only.

![Fuzzy search](assets/screenshots/search.png)

## License

No project license has been selected. Do not assume an open-source license.
