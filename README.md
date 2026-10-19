# pm

A project manager for people who start a lot of projects and finish few of them.

`pm` finds your projects on disk, reads their activity from git and their progress from GitHub issues or a markdown checklist, and asks you for only three things: what's in focus (max 3), the very next step, and where you left off.

No dependencies: Python 3.8+ standard library, `git` 2.21+, and optionally the [GitHub CLI](https://cli.github.com/) (`gh`) for issues. Works on macOS, Linux and Windows.

## Installation

| | Needed for | macOS | Windows |
|---|---|---|---|
| Python 3.8+ | everything | comes with Xcode Command Line Tools | `winget install Python.Python.3.13` |
| Git 2.21+ | everything | comes with Xcode Command Line Tools | `winget install Git.Git` |
| GitHub CLI | progress from GitHub issues (optional) | `brew install gh` | `winget install GitHub.cli` |
| Rust | the menu bar / tray light (optional) | [rustup.rs](https://rustup.rs) | `winget install Rustlang.Rustup` |

### macOS

1. **Install the tools** (skip any you already have):

   ```sh
   xcode-select --install                                          # git and python3
   brew install gh                                                 # optional: GitHub issues
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  # optional: menu bar light
   ```

2. **Get the code.** The repo is private, so sign in to GitHub first:

   ```sh
   gh auth login
   gh repo clone JustGritt/Project-Manager ~/orca/projects/Project-Manager
   ```

3. **Put `pm` on your PATH:**

   ```sh
   mkdir -p ~/.local/bin
   ln -s ~/orca/projects/Project-Manager/pm ~/.local/bin/pm
   echo $PATH | tr ':' '\n' | grep -qx "$HOME/.local/bin" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
   ```

   Open a new terminal (or run `rehash`) so the shell picks up the new command.

4. **First run.** This discovers your projects and opens the board:

   ```sh
   pm
   pm serve
   ```

5. **Keep it running** (optional). Start the board at login and add the menu bar light:

   ```sh
   pm autostart on       # board at http://localhost:4242 after every login
   pm tray on            # ● pm in the menu bar; the first build takes a minute
   ```

### Windows

Use **PowerShell** (Windows Terminal is the nicest). If `python` opens the Microsoft Store instead of running, turn off the `python.exe` alias in *Settings → Apps → Advanced app settings → App execution aliases*.

1. **Install the tools** (skip any you already have), then open a new PowerShell window:

   ```powershell
   winget install Python.Python.3.13
   winget install Git.Git
   winget install GitHub.cli          # optional: GitHub issues
   winget install Rustlang.Rustup     # optional: tray light
   ```

   Rust on Windows also needs the Visual Studio C++ Build Tools. Running `rustup-init` offers to install them; accept the default.

2. **Get the code.** The repo is private, so sign in to GitHub first:

   ```powershell
   gh auth login
   gh repo clone JustGritt/Project-Manager "$HOME\Projects\Project-Manager"
   ```

3. **Put `pm` on your PATH** so you can type `pm` instead of `python pm`. `pm.cmd` does the rest:

   ```powershell
   $pm = "$HOME\Projects\Project-Manager"
   [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$pm", "User")
   ```

   Open a new PowerShell window afterwards.

4. **First run.** `pm` only looks in `~`, `~/orca` and `~/orca/projects` by default, so tell it where your projects live:

   ```powershell
   pm root "$HOME\Projects"
   pm
   pm serve
   ```

5. **Keep it running** (optional). Start the board at login and add the tray light:

   ```powershell
   pm autostart on       # board at http://localhost:4242 after every sign-in
   pm tray on            # dot in the taskbar tray; the first build takes a few minutes
   ```

   New tray icons often start hidden under the **^** arrow. Drag the dot onto the taskbar to keep it visible.

### Linux

Same as macOS, with your package manager instead of Homebrew. The tray light also needs `libgtk-3-dev libayatana-appindicator3-dev` (Debian/Ubuntu names) to build.

### Finding projects

`pm` treats any folder containing `.git`, `project.godot`, `ProjectSettings`, `package.json`, `Cargo.toml` or `pyproject.toml` as a project. It searches the immediate subfolders of `~`, `~/orca` and `~/orca/projects`; add more places with `pm root <dir>`, a single folder with `pm add <path>`, and hide one with `pm ignore <name>`.

### Updating

```sh
cd ~/orca/projects/Project-Manager     # Windows: cd $HOME\Projects\Project-Manager
git pull
pm stop; pm start                      # reload the board
pm tray on                             # rebuilds the tray light if its code changed
```

### Uninstalling

```sh
pm tray off
pm autostart off
```

Then delete the `Project-Manager` folder, plus the `~/.local/bin/pm` link on macOS or the PATH entry on Windows. Your data is in `projects.json` inside that folder, so copy it first if you want to keep your notes.

## Web board

```sh
pm serve          # http://localhost:4242
```

- **Top row:** issues closed this week, focus / in motion / stalled split, and milestones within 3 tasks of done.
- **This week's focus:** up to 3 starred projects. **Pick for me** suggests what to focus on and says why.
- **Projects table:** current milestone progress, next step (click to edit), 12-week commit activity, last touched. Click a project name to see where you left off.
- **Stalled projects** (no activity for 3+ weeks) get **Revive / Park / Kill**. Parked and killed projects can be restored anytime.
- **Details panel:** full roadmap, what's left in the current milestone, blockers, decisions, commits and journal.

The server only listens on `127.0.0.1` and rejects requests from other origins.

### Start it at login

```sh
pm autostart on       # then bookmark http://localhost:4242
pm autostart status
pm autostart off
```

`pm start` / `pm stop` run the board in the background (or stop it) without touching the login item.

### Menu bar / tray light

```sh
pm tray on            # builds the app with cargo on first run
pm tray off
```

A small native Rust app (`tray/`, no webview: about 13 MB of memory, idle CPU) that shows a filled green dot while the board is running and a hollow ring when it isn't. Its menu lists this week's focus with next steps, ideas that are ready to start, and Open / Start / Stop board and "Start board at login". Needs [Rust](https://rustup.rs) to build; on Linux also `libgtk-3-dev libayatana-appindicator3-dev`.

Autostart uses each system's own login mechanism, no admin rights needed: a LaunchAgent on macOS (log in `~/Library/Logs/pm-board.log`), a systemd user service on Linux (or a desktop autostart entry where systemd isn't available), and a hidden launcher in the Startup folder on Windows.

## Idea inbox

New project ideas go into the inbox instead of becoming projects right away:

- An idea waits **7 days** before it can start (`idea_cooldown_days` in `projects.json`).
- Starting one needs a **free focus slot**. It creates the folder (default: `~/orca/projects/<Title>`), runs `git init`, writes a starter `ROADMAP.md` and puts the project in focus.
- Letting an idea go is counted as a win: it's a project you never had to abandon.

From the board use the inbox section; from the terminal use `pm idea "..."`, `pm ideas`, `pm idea start <id>` and `pm idea drop <id>`.

## Where progress comes from

1. **GitHub issues and milestones**, if the repo has issues. Each milestone's progress is closed / total issues, and the current milestone is the first unfinished one. Labels containing `block` mark blockers; `decision` or `question` mark decisions waiting on you; `in-progress` floats issues to the top.
2. **A markdown checklist** otherwise: `ROADMAP.md`, `TODO.md` or `docs/roadmap.md`. Headings are milestones and `- [ ]` / `- [x]` items are tasks:

   ```md
   ## MVP
   - [x] Player movement
   - [ ] Jump feel

   ## Release
   - [ ] Windows build
   ```

   Point a project at any checklist with `pm roadmap <name> <file>`. An explicit choice wins over GitHub issues. Tasks can be checked off from the details panel, which edits the file.

## CLI

```
pm                      the board: focus, in motion, stalled
pm serve [port]         the web board
pm start | pm stop      run the web board in the background, or stop it
pm autostart [on|off]   start the web board at login
pm tray [on|off]        the menu bar / tray light
pm review               triage stalled projects one by one (do this weekly)
pm idea "..." ["why"]   park a new project idea
pm ideas [--all]        the idea inbox
pm idea start|drop <id>
pm focus|unfocus <name>
pm next <name> "..."    the very next concrete step
pm leftoff <name> "..." where you left off
pm why <name> "..."     why this project matters to you
pm block <name> "..."   / pm unblock <name>
pm note <name> "..."    journal entry
pm park|drop|done <name> [note]
pm revive <name>
pm show <name>          details, roadmap, recent commits, journal
pm list [status]
pm roadmap <name> [file]
pm add <path> [name] · pm root <dir> · pm ignore <name>
```

Names can be abbreviated: `pm show grim`.

## Data

Everything you enter lives in `projects.json` next to the script (git-ignored). GitHub responses are cached for 10 minutes in `.cache/`.
