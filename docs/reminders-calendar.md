# Reminders and Calendar

Both groups use Apple's EventKit, so every account that Reminders and Calendar show is available: iCloud, Google, Exchange, subscriptions and delegates.
Flags, tags, sections, subtasks and attachments of reminders go through the private ReminderKit framework, the same one the Reminders app uses, checked on macOS 27.
Changes are saved at once and synchronized by macOS. No app is launched and no `sync` step exists.

Access is granted once per terminal application: run `abdy reminders access` and `abdy calendar access`, allow the system dialog,
or enable the application in System Settings, Privacy and Security, Reminders and Calendars. Without access, commands return exit code 1 with that hint.

```sh
abdy reminders lists
reminder=$(abdy reminders add "Buy milk" --list Groceries --due 2026-10-07T18:00 --alarm 30 --priority 1)
abdy reminders ls --list Groceries --long
abdy reminders edit "$reminder" --title "Buy oat milk" --clear-alarms
abdy reminders done "$reminder"
abdy reminders search milk --all
abdy reminders mv "$reminder" --list Home
abdy reminders add "Buy nails" --parent "$reminder" --tag hardware --flag
abdy reminders mksection Produce --list Groceries
abdy reminders mv "$reminder" --section Produce
abdy reminders attachments add "$reminder" --file photo.jpg
abdy reminders attachments export "$reminder" --directory saved-files
abdy reminders ls --flagged --tag errands --long

abdy calendar calendars
abdy calendar add "Dentist" --calendar Personal --start 2026-10-09T14:00 --duration 45 --alarm 60
abdy calendar add "Standup" --calendar Work --start 2026-10-06T09:30 --duration 15 --repeat weekly --until 2026-12-31
abdy calendar events --from 2026-10-06 --to 2026-10-13 --long
abdy calendar edit "$event" --occurrence 2026-10-13T09:30:00+11:00 --span this --start 2026-10-13T10:00
abdy calendar rm "$event" --occurrence 2026-10-13T09:30:00+11:00 --span future
```

Dates are ISO 8601: `2026-10-07T09:00`, `2026-10-07T09:00:00+11:00` or `2026-10-07` for a whole day. Output uses the local time zone.
Lists and calendars are selected by name, UUID or a unique prefix of 8 characters. An ambiguous name lists the candidates with their accounts.
Reminders and events are selected by UUID or a unique prefix. Event prefixes match events from 1 year ago to 2 years ahead.
`--alarm` is minutes before the due date or start, repeatable. Alarms are always listed in ascending order.
Location reminders: `--arrive "place or address"` or `--leave "..."` with `--radius` meters (default 100). The place is geocoded, a coordinate pair is used as is: `--arrive=-33.8688,151.2093`. `edit --clear-location` removes it. `--repeat daily|weekly|monthly|yearly` with `--interval`, `--until` or `--count`.
A repeating event needs `--occurrence` from `events --json` and `--span this` or `--span future` for `edit` and `rm`. Future edits start a new series with a new UUID.
All-day events include both `--start` and `--end` days. Read-only calendars such as subscriptions and holidays are listed and refuse writes.
Attendees are shown by `calendar show` but cannot be invited. Reminders and Calendar have no trash: `rm` deletes for good.
`done` on a repeating reminder leaves the original open with its next due date and creates a completed copy with a new id. `done`, `undone`, `mv`, `rm`, `flag`, `unflag` and `tags` take many ids or `-` for ids from stdin, check every id first and save once.

Flags: `flag`, `unflag`, `add --flag`, `edit --flag` or `--no-flag`, `ls --flagged`.
Tags: `--tag "errands, urgent"` on `add` replaces the tags, `tags <id> --add` and `--remove` change them, `tags` alone lists every tag with its count, `ls --tag errands` filters. Names are written with or without `#`.
Sections: `sections --list L`, `mksection`, `renamesection`, `rmsection`, then `add --section`, `mv --section` and `edit --clear-section`. A section is selected by title, UUID or prefix inside its list. Deleting a section keeps its reminders.
Subtasks: `add "title" --parent <id>` creates a subtask in the parent's list, `subtasks <id>` lists them, `edit --parent` and `--clear-parent` move an existing reminder in or out. Deleting the parent deletes its subtasks, moving a subtask to another list makes it top-level.
Attachments: `attachments add --file` stores an image or any file, `--url` stores a link, `ls`, `export --directory` or `export --attachment A --file F`, `rm --attachment A`. Reminders shows images and links, other files are stored and exported but not displayed by the app. Export never overwrites and gives duplicate names a numeric suffix.

## Reminders commands

| Task | Commands |
| --- | --- |
| Access | `access` |
| Lists | `lists`, `mklist`, `renamelist`, `rmlist` |
| Read | `ls`, `show`, `search` |
| Write | `add`, `edit`, `done`, `undone`, `mv`, `rm`, `flag`, `unflag`, `tags` |
| Structure | `subtasks`, `sections`, `mksection`, `renamesection`, `rmsection` |
| Files | `attachments ls`, `attachments add`, `attachments export`, `attachments rm` |

JSON reminder fields: `id`, `title`, `notes`, `listID`, `list`, `due`, `dueHasTime`, `priority`, `completed`, `completionDate`, `url`, `alarms`, `location` (title, latitude, longitude, radius, proximity arrive or leave), `recurrence`, `flagged`, `tags`, `parentID`, `sectionID`, `section`, `attachments` (id, kind image, file or url, uti, name, path, size, width, height, url), `created`, `modified`. `show --json` adds `subtasks`.

## Calendar commands

| Task | Commands |
| --- | --- |
| Access | `access` |
| Calendars | `calendars`, `mkcal`, `renamecal`, `rmcal` |
| Read | `events`, `show` |
| Write | `add`, `edit`, `rm`, `mv` |

JSON event fields: `id`, `title`, `calendarID`, `calendar`, `start`, `end`, `allDay`, `location`, `notes`, `url`, `alarms`, `recurrence`, `occurrence`, `isDetached`, `status`, `organizer`, `attendees`, `created`, `modified`.
JSON calendar and list fields: `id`, `title`, `kind`, `source`, `sourceID`, `type`, `color`, `readOnly`, `isDefault`. Lists add `count`.
`abdy reminders help` and `abdy calendar help` list every command with its options.
