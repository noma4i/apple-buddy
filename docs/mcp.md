# MCP server for AI agents

Start the built-in MCP server with `abdy mcp`. Add this entry to your agent's MCP config:

```json
{
  "mcpServers": {
    "apple-buddy": {
      "command": "/absolute/path/to/abdy",
      "args": ["mcp"]
    }
  }
}
```

Use `command -v abdy` to find the executable path. The agent starts and stops the server.
Tools cover the CLI commands, including search, folders, pin, attachments, backup and restore.
Each tool describes its parameters. Names are the command path with underscores, for example `notes_search`, `notes_attachments_export` and `notes_table_set`.
Calls with the old flat names such as `search` or `attachments_export` still work.
Call `help` with a tool name for full command help. Results contain structured JSON and the same data as the CLI.
Set `html` or `csv` to `-` and pass text in `stdin` to avoid creating input files.
Requests run one at a time. Writes save locally, the `notes_sync` tool sends them to iCloud. Only `notes_open` displays Notes.
Stdio needs no port, token, Node.js or separate server executable.

## Tools

The server exposes 1 tool per CLI command, named after the command path: `notes_search`, `notes_attachments_export`, `reminders_add`, `calendar_events`, `version` and `help`.
Each tool's description is the CLI help of that command, its parameters are the CLI options and arguments with JSON types.
Repeated arguments such as `ids`, `calendar` and `alarm` are arrays. Flags are booleans. `--json` is implied and not a parameter.

## Results

A successful call returns `structuredContent` with the same JSON the CLI prints with `--json`, plus the JSON as text.
Lists come back under `data` when the CLI prints an array. A failed call returns `isError: true` and the CLI error text.
`help` returns plain text.

## Workflow for agents

1. Read the server instructions: they state the id rules, the sync rule for Notes and the access rule for Reminders and Calendar.
2. Find objects first: `notes_search` or `notes_ls`, `reminders_ls`, `calendar_events`, `calendar_calendars`. Every id, name, path and URL in a result is accepted as input.
3. Write with the matching tool. Notes writes save locally, call `notes_sync` once at the end. Reminders and Calendar writes are final.
4. On `isError`, read the text: it names the object, its state and the action, for example `Note <UUID> is shared and cannot be moved`, or asks for `reminders_access`.

Writes are serialized: 1 tool call runs at a time. Reads do not launch Notes. `notes_open` is the only tool that shows a window.
