# pm

A project manager for people who start a lot of projects and finish few of them.

`pm` finds your projects on disk, reads their activity from git and their progress from GitHub issues or a markdown checklist, and asks you for only three things: what's in focus (max 3), the very next step, and where you left off.

No dependencies: Python 3 standard library, `git`, and optionally the [GitHub CLI](https://cli.github.com/) (`gh`) for issues.

## Setup

```sh
git clone git@github.com:JustGritt/Project-Manager.git
ln -s "$PWD/Project-Manager/pm" ~/.local/bin/pm   # any directory on your PATH
gh auth login                                     # optional, for GitHub issues
pm                                                # first run discovers your projects
```

Projects are discovered in `~`, `~/orca` and `~/orca/projects` by default (any folder with `.git`, `project.godot`, `ProjectSettings`, `package.json`, `Cargo.toml` or `pyproject.toml`). Add more with `pm root <dir>`.

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
pm review               triage stalled projects one by one (do this weekly)
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
