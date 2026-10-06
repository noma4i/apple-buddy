# Install and update

Requires macOS, Apple Notes, Homebrew and Apple's Command Line Tools.
Install from our own tap, not Homebrew Core:

```sh
brew tap noma4i/apple-buddy https://github.com/noma4i/apple-buddy.git
brew install noma4i/apple-buddy/abdy
```

Homebrew builds the CLI on your Mac and installs `abdy` with the `nb` alias. Update it with:

```sh
brew update
brew upgrade noma4i/apple-buddy/abdy
```

If you installed the old tap, remove it first: `brew uninstall nb && brew untap noma4i/notes-buddy`.
While the repository is private, your Git credentials need repository access.
With GitHub CLI, configure them using `gh auth login` and `gh auth setup-git`.
GitHub installation becomes available after the tap changes are pushed and their workflow finishes.

## Access

`abdy notes`, `abdy reminders` and `abdy calendar` run inside their own application, `Abdy.app` (bundle id `com.noma4i.abdy`).
`abdy` builds it on first use in `~/Library/Application Support/apple-buddy` and rebuilds it after an update.
Access belongs to `Abdy.app`, not to the terminal, the agent host, `ssh` or `launchd`, so every caller gets the same rights.

1. Reminders and Calendar: run `abdy reminders access` and `abdy calendar access` once and allow the system dialog.
2. Notes: macOS shows no dialog. Add `Abdy.app` to System Settings, Privacy and Security, Full Disk Access. The error message of `abdy notes` names the exact path.

Rights survive updates: the signature requirement is the bundle id, not the file hash.
`help`, `version` and `mcp` do not use the application. A command costs about 0.1 s more than a direct run.

## From source

```sh
swift build -c release
.build/release/abdy help
```
