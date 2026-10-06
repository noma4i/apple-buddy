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

Notes: the terminal application needs Full Disk Access when database access is denied.
Reminders and Calendar: run `abdy reminders access` and `abdy calendar access` once, allow the system dialog.
Access belongs to the terminal application that runs `abdy`, including an agent's host application.

## From source

```sh
swift build -c release
.build/release/abdy help
```
