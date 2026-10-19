#!/usr/bin/env python3
"""pm — a project manager for people who start a lot of projects.

Activity is read from git automatically; you only record intent:
what's in focus, why it matters, and the very next step.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta
from urllib.parse import unquote, urlparse, parse_qs

HERE = os.path.dirname(os.path.realpath(__file__))
DATA = os.path.join(HERE, "projects.json")
WEB = os.path.join(HERE, "web")
GH_CACHE = os.path.join(HERE, ".cache", "github.json")
GH_TTL = 600
WEEKS = 12

DEFAULTS = {
    "roots": ["~", "~/orca", "~/orca/projects"],
    "ignore": ["Temp", "Project-Manager", "Library", "Applications"],
    "focus_limit": 3,
    "idea_cooldown_days": 7,
    "projects": {},
    "ideas": [],
}

ACTIVE_DAYS, COOLING_DAYS = 7, 21
STATUSES = ("active", "parked", "done", "dropped")

if os.name == "nt":
    os.system("")  # turns on ANSI colors in the classic Windows console
# pythonw (Windows autostart) has no console at all: sys.stdout is None.
if sys.stdout and (sys.stdout.encoding or "").lower().replace("-", "") != "utf8":
    sys.stdout.reconfigure(errors="replace")  # ★ and → on a non-UTF-8 console or locale

C = {"r": "\033[31m", "g": "\033[32m", "y": "\033[33m", "b": "\033[34m",
     "m": "\033[35m", "c": "\033[36m", "dim": "\033[2m", "bold": "\033[1m", "x": "\033[0m"}
if not (sys.stdout and sys.stdout.isatty()) or os.environ.get("NO_COLOR"):
    C = {k: "" for k in C}


def col(text, *styles):
    return "".join(C[s] for s in styles) + str(text) + C["x"]


# ---------- storage ----------

def load():
    if not os.path.exists(DATA):
        return json.loads(json.dumps(DEFAULTS))
    with open(DATA, encoding="utf-8") as f:
        db = json.load(f)
    for k, v in DEFAULTS.items():
        db.setdefault(k, json.loads(json.dumps(v)))
    return db


def save(db):
    tmp = DATA + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, DATA)


def today():
    return date.today().isoformat()


def log(p, note):
    p.setdefault("log", []).append({"date": today(), "note": note})


# ---------- discovery & activity ----------

def git(path, *args):
    try:
        out = subprocess.run(["git", "-C", path, *args], capture_output=True, encoding="utf-8", errors="replace", timeout=10)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def is_project(path):
    markers = (".git", "project.godot", "ProjectSettings", "package.json", "Cargo.toml", "pyproject.toml")
    return any(os.path.exists(os.path.join(path, m)) for m in markers)


def discover(db):
    found = {}
    for root in db["roots"]:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if name.startswith(".") or name in db["ignore"] or not os.path.isdir(path):
                continue
            if is_project(path):
                found.setdefault(name, path)
    return found


def activity(path):
    """Last time the project was touched: latest commit or latest uncommitted edit."""
    info = {"last": None, "commits": 0, "dirty": 0, "subject": ""}
    if os.path.isdir(os.path.join(path, ".git")):
        line = git(path, "log", "-1", "--format=%ct|%s")
        if line:
            ts, _, info["subject"] = line.partition("|")
            info["last"] = datetime.fromtimestamp(int(ts)).date()
            info["commits"] = int(git(path, "rev-list", "--count", "HEAD") or 0)
        dirty = [l[3:].strip('"') for l in git(path, "status", "--porcelain").splitlines()]
        info["dirty"] = len(dirty)
        for rel in dirty[:200]:
            try:
                d = datetime.fromtimestamp(os.path.getmtime(os.path.join(path, rel))).date()
            except OSError:
                continue
            if info["last"] is None or d > info["last"]:
                info["last"] = d
    elif os.path.isdir(path):
        info["last"] = datetime.fromtimestamp(os.path.getmtime(path)).date()
    return info


def idle_days(info):
    return (date.today() - info["last"]).days if info["last"] else None


def heat(days):
    if days is None:
        return col("● unknown", "dim")
    if days <= ACTIVE_DAYS:
        return col("● active ", "g")
    if days <= COOLING_DAYS:
        return col("● cooling", "y")
    return col("● stalled", "r")


def ago(days):
    if days is None:
        return "?"
    if days == 0:
        return "today"
    if days < 14:
        return f"{days}d ago"
    if days < 60:
        return f"{days // 7}w ago"
    return f"{days // 30}mo ago"


# ---------- helpers ----------

def sync(db, quiet=False):
    """Add newly discovered projects; flag ones whose folder vanished."""
    new = []
    for name, path in discover(db).items():
        if name not in db["projects"]:
            db["projects"][name] = {"path": path, "status": "active", "focus": False,
                                    "next": "", "why": "", "added": today(), "log": []}
            new.append(name)
    if new and not quiet:
        print(col(f"Found {len(new)} new project(s): ", "c") + ", ".join(new))
    return new


def find(db, query):
    q = query.lower()
    names = list(db["projects"])
    exact = [n for n in names if n.lower() == q]
    hits = exact or [n for n in names if n.lower().startswith(q)] or [n for n in names if q in n.lower()]
    if len(hits) == 1:
        return hits[0], db["projects"][hits[0]]
    if not hits:
        sys.exit(col(f"No project matches '{query}'.", "r") + " Try `pm list`.")
    sys.exit(col(f"'{query}' is ambiguous: ", "y") + ", ".join(hits))


def try_focus(db, name):
    """Focus a project; returns an error message if the focus limit is hit."""
    focused = [n for n, q in db["projects"].items() if q.get("focus") and n != name]
    if len(focused) >= db["focus_limit"]:
        return f"Focus is full ({', '.join(focused)}). Finish, park, or unfocus one first."
    p = db["projects"][name]
    p["focus"], p["status"] = True, "active"
    log(p, "focused")
    return None


# ---------- idea inbox ----------
# New ideas wait out a cooldown before they can become projects, and only
# start when a focus slot is free. Most lose their shine while waiting.

def idea_view(db, idea):
    age = (date.today() - date.fromisoformat(idea["added"])).days
    left = max(0, db["idea_cooldown_days"] - age)
    return {**idea, "age": age, "daysLeft": left, "ready": left == 0,
            "defaultPath": tilde(idea_path(db, idea["title"]))}


def tilde(path):
    """~/... for paths under home, on any OS."""
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path == home or path.startswith(home + os.sep) else path


def idea_path(db, title):
    folder = re.sub(r"[^A-Za-z0-9_-]+", "-", title).strip("-") or "new-project"
    root = next((r for r in db["roots"] if r.rstrip("/").endswith("projects")), db["roots"][-1])
    return os.path.join(os.path.expanduser(root), folder)


def find_idea(db, query):
    waiting = [i for i in db["ideas"] if i["status"] == "waiting"]
    q = str(query).lower()
    hits = [i for i in waiting if str(i["id"]) == q] or [i for i in waiting if i["title"].lower().startswith(q)]
    if len(hits) != 1:
        raise ValueError(f"No waiting idea matches '{query}'." if not hits else f"'{query}' matches several ideas.")
    return hits[0]


def add_idea(db, title, pitch=""):
    title = title.strip()
    if not title:
        raise ValueError("An idea needs a title.")
    idea = {"id": max((i["id"] for i in db["ideas"]), default=0) + 1, "title": title,
            "pitch": pitch.strip(), "added": today(), "status": "waiting"}
    db["ideas"].append(idea)
    return idea


def drop_idea(db, query, note=""):
    idea = find_idea(db, query)
    idea.update(status="dropped", closed=today(), note=note.strip())
    return idea


def start_idea(db, query, path=None):
    """Turn a ready idea into a focused project: folder, git repo and a starter ROADMAP.md."""
    idea = find_idea(db, query)
    view = idea_view(db, idea)
    if not view["ready"]:
        raise ValueError(f"'{idea['title']}' is still cooling off: ready in {plural(view['daysLeft'], 'day')}.")
    focused = [n for n, p in db["projects"].items() if p.get("focus")]
    if len(focused) >= db["focus_limit"]:
        raise ValueError(f"Focus is full ({', '.join(focused)}). Finish, park or unfocus one first: "
                         "a new project should take a free slot, not a fourth one.")
    path = os.path.abspath(os.path.expanduser(path.strip())) if path and path.strip() else idea_path(db, idea["title"])
    name = os.path.basename(path)
    if name in db["projects"]:
        raise ValueError(f"A project named {name} already exists.")
    if os.path.exists(path) and not os.path.isdir(path):
        raise ValueError(f"{path} exists and is not a folder.")
    created = not os.path.exists(path)
    if created:
        os.makedirs(path)
        subprocess.run(["git", "init", "-q", path], check=False)
        pitch = f"\n> {idea['pitch']}\n" if idea["pitch"] else ""
        with open(os.path.join(path, "ROADMAP.md"), "w", encoding="utf-8") as f:
            f.write(f"# {idea['title']}\n{pitch}\n## MVP\n"
                    "- [ ] Write down what \"done\" means for the MVP\n"
                    "- [ ] Build the smallest slice you can show someone\n")
    db["projects"][name] = {"path": path, "status": "active", "focus": True, "next": "", "why": idea["pitch"],
                            "added": today(), "log": [{"date": idea["added"], "note": f"idea: {idea['title']}"},
                                                      {"date": today(), "note": "started from the idea inbox"}]}
    idea.update(status="started", closed=today(), project=name)
    return name, path, created


def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def need(args, n, usage):
    if len(args) < n:
        sys.exit(f"usage: pm {usage}")


def row(name, p, info, width):
    days = idle_days(info)
    star = col("★ ", "m") if p.get("focus") else "  "
    dirty = col(f" +{info['dirty']} uncommitted", "y") if info["dirty"] else ""
    line = f"{star}{name:<{width}}  {heat(days)}  {col(ago(days).rjust(8), 'dim')}{dirty}"
    nxt = p.get("next")
    line += "\n" + " " * (width + 4) + (col("→ " + nxt, "c") if nxt else col("→ no next step set", "dim"))
    if p.get("blocker"):
        line += "\n" + " " * (width + 4) + col("⛔ " + p["blocker"], "r")
    return line


# ---------- commands ----------

def cmd_status(db, args):
    sync(db)
    projects = {n: p for n, p in db["projects"].items() if os.path.exists(p["path"])}
    infos = {n: activity(p["path"]) for n, p in projects.items()}
    width = max((len(n) for n in projects), default=10)
    by_idle = lambda n: idle_days(infos[n]) if idle_days(infos[n]) is not None else 9999

    focus = sorted((n for n, p in projects.items() if p.get("focus")), key=by_idle)
    live = [n for n, p in projects.items() if p["status"] == "active" and not p.get("focus")]
    warm = sorted((n for n in live if by_idle(n) <= COOLING_DAYS), key=by_idle)
    cold = sorted((n for n in live if by_idle(n) > COOLING_DAYS), key=by_idle)
    shelved = {s: sorted(n for n, p in projects.items() if p["status"] == s) for s in ("parked", "done", "dropped")}

    limit = db["focus_limit"]
    print(col(f"\nFOCUS ({len(focus)}/{limit})", "bold", "m"))
    if focus:
        for n in focus:
            print(row(n, projects[n], infos[n], width))
            if by_idle(n) > ACTIVE_DAYS:
                print(" " * (width + 4) + col(f"⚠ in focus but untouched for {by_idle(n)} days — work on it, or unfocus it", "r"))
    else:
        print(col("  Nothing in focus. Pick up to 3: pm focus <name>", "dim"))

    if warm:
        print(col("\nIN MOTION (not in focus)", "bold"))
        for n in warm:
            print(row(n, projects[n], infos[n], width))
    if cold:
        print(col(f"\nSTALLED ({len(cold)}) — decide: focus, park, or drop", "bold", "r"))
        for n in cold:
            print(row(n, projects[n], infos[n], width))

    parts = [f"{s} {len(v)}" for s, v in shelved.items() if v]
    if parts:
        print(col("\nSHELF  ", "bold") + col(" · ".join(parts) + "   (pm list to see them)", "dim"))
    waiting = [idea_view(db, i) for i in db["ideas"] if i["status"] == "waiting"]
    if waiting:
        ready = sum(i["ready"] for i in waiting)
        print(col("IDEAS  ", "bold") + col(f"{len(waiting)} waiting" + (f" · {ready} ready" if ready else "")
                                           + "   (pm ideas)", "dim"))

    tips = []
    if len(warm) + len(focus) > limit:
        tips.append(f"{len(warm) + len(focus)} projects in motion — that's more than your focus limit of {limit}.")
    if cold:
        tips.append(f"{len(cold)} stalled projects are still marked active. Run `pm review` to triage them.")
    missing = [n for n in focus if not projects[n].get("next")]
    if missing:
        tips.append(f"Focused project(s) without a next step: {', '.join(missing)}. Run `pm next <name> \"...\"`.")
    for t in tips:
        print(col("\n» " + t, "y"))
    print()
    save(db)


def cmd_focus(db, args):
    need(args, 1, "focus <name>")
    name, p = find(db, args[0])
    err = try_focus(db, name)
    if err:
        sys.exit(col(err, "r") + " That's the point.")
    save(db)
    print(col(f"★ {name} is in focus.", "m"))
    if not p.get("next"):
        print(col(f"  Set the very next step: pm next {name} \"...\"", "dim"))


def cmd_unfocus(db, args):
    need(args, 1, "unfocus <name>")
    name, p = find(db, args[0])
    p["focus"] = False
    log(p, "unfocused")
    save(db)
    print(f"{name} removed from focus.")


def set_status(status, verb):
    def cmd(db, args):
        need(args, 1, f"{verb} <name> [note]")
        name, p = find(db, args[0])
        note = " ".join(args[1:])
        p["status"] = status
        if status != "active":
            p["focus"] = False
        log(p, f"{status}" + (f": {note}" if note else ""))
        save(db)
        msg = {"parked": "parked. It'll wait, guilt-free.", "done": "is DONE. Nice.",
               "dropped": "dropped. Letting go is a decision, not a failure.",
               "active": "is back on the active list."}[status]
        print(f"{name} {msg}")
    return cmd


def cmd_text(field, label):
    def cmd(db, args):
        need(args, 2, f"{field} <name> \"text\"")
        name, p = find(db, args[0])
        p[field] = " ".join(args[1:])
        log(p, f"{label}: {p[field]}")
        save(db)
        print(f"{name} → {label}: {col(p[field], 'c')}")
    return cmd


def cmd_unblock(db, args):
    need(args, 1, "unblock <name>")
    name, p = find(db, args[0])
    p["blocker"] = ""
    log(p, "unblocked")
    save(db)
    print(f"{name} is unblocked.")


def cmd_idea(db, args):
    need(args, 1, 'idea "title" ["why it\'s exciting"]  |  idea start <id> [path]  |  idea drop <id> [note]')
    try:
        if args[0] == "start" and len(args) > 1:
            name, path, created = start_idea(db, args[1], args[2] if len(args) > 2 else None)
            save(db)
            print(col(f"★ {name} started and in focus.", "m") + f"  {path}" + (" (new repo + ROADMAP.md)" if created else ""))
        elif args[0] == "drop" and len(args) > 1:
            idea = drop_idea(db, args[1], " ".join(args[2:]))
            save(db)
            print(f"Let go of '{idea['title']}'. That's a project you'll never have to abandon.")
        else:
            idea = add_idea(db, args[0], " ".join(args[1:]))
            save(db)
            print(f"Parked idea #{idea['id']}: {idea['title']}. It can become a project in "
                  f"{plural(db['idea_cooldown_days'], 'day')}, if you still want it.")
    except ValueError as e:
        sys.exit(col(str(e), "r"))


def cmd_ideas(db, args):
    ideas = [idea_view(db, i) for i in db["ideas"] if i["status"] == "waiting"]
    if not ideas:
        print('No ideas waiting. Next time inspiration strikes: pm idea "..."')
    for i in sorted(ideas, key=lambda i: i["daysLeft"]):
        when = col("ready", "g") if i["ready"] else col(f"ready in {plural(i['daysLeft'], 'day')}", "dim")
        print(f"  #{i['id']:<3} {i['title']}  {when}" + (col(f"\n       {i['pitch']}", "dim") if i["pitch"] else ""))
    gone = [i for i in db["ideas"] if i["status"] == "dropped"]
    if gone:
        print(col(f"\n  {plural(len(gone), 'idea')} let go so far.", "dim"))
    if "--all" in args:
        for i in db["ideas"]:
            if i["status"] != "waiting":
                print(col(f"  #{i['id']:<3} {i['title']}  [{i['status']} {i.get('closed', '')}]", "dim"))


def cmd_roadmap(db, args):
    need(args, 1, "roadmap <name> [file]   (no file: clear and auto-detect)")
    name, p = find(db, args[0])
    if len(args) < 2:
        p.pop("roadmap", None)
        save(db)
        rel = roadmap_file(p)
        return print(f"{name}: auto-detect → {rel or 'no roadmap file found'}")
    rel = os.path.relpath(os.path.abspath(args[1]), p["path"]) if os.path.isabs(args[1]) else args[1]
    if not os.path.isfile(os.path.join(p["path"], rel)):
        sys.exit(f"No file {rel} in {p['path']}")
    p["roadmap"] = rel
    log(p, f"roadmap: {rel}")
    save(db)
    r = summarize_roadmap(p["path"], rel)
    print(f"{name} → {rel}" + (f"  ({r['done']}/{r['total']} tasks, {len(r['milestones'])} milestones)" if r else "  (no checkboxes found)"))


def cmd_note(db, args):
    need(args, 2, "note <name> \"text\"")
    name, p = find(db, args[0])
    log(p, " ".join(args[1:]))
    save(db)
    print(f"Logged on {name}.")


def cmd_show(db, args):
    need(args, 1, "show <name>")
    name, p = find(db, args[0])
    info = activity(p["path"])
    days = idle_days(info)
    print(col(f"\n{name}", "bold") + ("  " + col("★ focus", "m") if p.get("focus") else "") + f"  [{p['status']}]")
    print(col(p["path"], "dim"))
    print(f"Activity: {heat(days)} {ago(days)}  ·  {info['commits']} commits"
          + (col(f"  ·  {info['dirty']} uncommitted files", "y") if info["dirty"] else ""))
    print(f"Why:      {p.get('why') or col('(not set — pm why ' + name + ' \"...\")', 'dim')}")
    print(f"Next:     {col(p['next'], 'c') if p.get('next') else col('(not set — pm next ' + name + ' \"...\")', 'dim')}")
    if p.get("leftoff"):
        print(f"Left off: {p['leftoff']}")
    rel = roadmap_file(p)
    roadmap = summarize_roadmap(p["path"], rel) if rel else None
    if roadmap:
        cur = next((m for m in roadmap["milestones"] if m["number"] == roadmap["current"]), None)
        print(f"Roadmap:  {rel}  ·  {roadmap['done']}/{roadmap['total']} tasks"
              + (f"  ·  current: {cur['title']} ({cur['closed']}/{cur['total']})" if cur else "  ·  all done"))
    commits = git(p["path"], "log", "-5", "--format=%cs  %s")
    if commits:
        print(col("\nRecent commits", "bold"))
        print("\n".join("  " + c for c in commits.splitlines()))
    if p.get("log"):
        print(col("\nJournal", "bold"))
        for e in p["log"][-8:]:
            print(f"  {col(e['date'], 'dim')}  {e['note']}")
    print()


def cmd_list(db, args):
    sync(db, quiet=True)
    want = args[0] if args else None
    for status in STATUSES:
        if want and status != want:
            continue
        names = sorted(n for n, p in db["projects"].items() if p["status"] == status)
        if not names:
            continue
        print(col(f"\n{status.upper()} ({len(names)})", "bold"))
        for n in names:
            p = db["projects"][n]
            print(("★ " if p.get("focus") else "  ") + n + (col("  → " + p["next"], "dim") if p.get("next") else ""))
    print()
    save(db)


def ask(prompt):
    try:
        return input(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        print()
        save(DB_REF[0])
        sys.exit(0)


def cmd_review(db, args):
    """Walk through stalled active projects one at a time and make a call on each."""
    sync(db)
    queue = []
    for n, p in db["projects"].items():
        if p["status"] != "active" or not os.path.exists(p["path"]):
            continue
        info = activity(p["path"])
        d = idle_days(info)
        if p.get("focus") or d is None or d > COOLING_DAYS:
            queue.append((d if d is not None else 9999, n, info))
    queue.sort(reverse=True)
    if not queue:
        print("Nothing to review. Everything active is in motion. 🎉")
        return
    print(col(f"\nWeekly review: {len(queue)} project(s). Enter to skip, q to quit.\n", "bold"))
    for d, n, info in queue:
        p = db["projects"][n]
        print(col(n, "bold") + f"  {heat(d if d != 9999 else None)} {ago(d if d != 9999 else None)}"
              f"  ·  last: {info['subject'][:60] or '—'}")
        if p.get("why"):
            print(col(f"  why: {p['why']}", "dim"))
        if p.get("next"):
            print(col(f"  next: {p['next']}", "dim"))
        choice = ask("  [f]ocus  [k]eep  [p]ark  [d]rop  [x] done  [q]uit > ").lower()
        if choice == "q":
            break
        if choice == "f":
            err = try_focus(db, n)
            if err:
                print(col(f"  {err} Kept instead.", "y"))
        elif choice in ("p", "d", "x"):
            status = {"p": "parked", "d": "dropped", "x": "done"}[choice]
            p["status"], p["focus"] = status, False
            note = ask("  one-line note (optional) > ")
            log(p, f"{status} (review)" + (f": {note}" if note else ""))
            print()
            continue
        if choice in ("f", "k"):
            nxt = ask(f"  next step{' [' + p['next'] + ']' if p.get('next') else ''} > ")
            if nxt:
                p["next"] = nxt
                log(p, f"next: {nxt}")
        save(db)
        print()
    save(db)
    print(col("Review saved. Run `pm` to see the board.", "g"))


def cmd_add(db, args):
    need(args, 1, "add <path> [name]")
    path = os.path.abspath(os.path.expanduser(args[0]))
    if not os.path.isdir(path):
        sys.exit(f"Not a directory: {path}")
    name = args[1] if len(args) > 1 else os.path.basename(path)
    db["projects"][name] = {"path": path, "status": "active", "focus": False,
                            "next": "", "why": "", "added": today(), "log": []}
    save(db)
    print(f"Added {name}.")


def cmd_root(db, args):
    need(args, 1, "root <dir>   (adds a folder to scan for projects)")
    if args[0] not in db["roots"]:
        db["roots"].append(args[0])
    sync(db)
    save(db)


def cmd_ignore(db, args):
    need(args, 1, "ignore <name>")
    name, _ = find(db, args[0])
    db["ignore"].append(name)
    del db["projects"][name]
    save(db)
    print(f"{name} will no longer be tracked.")


# ---------- github ----------
# Issues are the tickets, milestones are the roadmap. Progress = closed / total
# per milestone; the "current" milestone is the first unfinished one.

GH_QUERY = """
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    url
    milestones(first: 50, states: [OPEN, CLOSED], orderBy: {field: NUMBER, direction: ASC}) {
      nodes {
        number title state url dueOn
        open: issues(states: OPEN) { totalCount }
        closed: issues(states: CLOSED) { totalCount }
      }
    }
    openIssues: issues(states: OPEN, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes { number title url updatedAt milestone { number } labels(first: 12) { nodes { name color } } }
    }
    closedIssues: issues(states: CLOSED, first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes { number title url closedAt }
    }
  }
}"""

BLOCKED = re.compile(r"block", re.I)
DECISION = re.compile(r"decision|question|needs[- ]?(info|design)", re.I)
DOING = re.compile(r"in[- ]?progress|doing|wip", re.I)
PRIORITY = re.compile(r"^(?:p|priority[:/ -]?)([0-4])$", re.I)

_gh_lock = threading.Lock()


def github_slug(path):
    url = git(path, "remote", "get-url", "origin")
    m = re.match(r"(?:git@github\.com:|https://github\.com/)([^/]+)/(.+?)(?:\.git)?/?$", url)
    return f"{m[1]}/{m[2]}" if m else None


def fetch_github(slug):
    owner, name = slug.split("/", 1)
    try:
        out = subprocess.run(["gh", "api", "graphql", "-f", f"query={GH_QUERY}",
                              "-f", f"owner={owner}", "-f", f"name={name}"],
                             capture_output=True, encoding="utf-8", errors="replace", timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"error": str(e)}
    if out.returncode != 0:
        return {"error": (out.stderr or out.stdout).strip()[:300]}
    return json.loads(out.stdout)["data"]["repository"]


def read_gh_cache():
    try:
        with open(GH_CACHE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def github_all(slugs, refresh=False, background=False):
    """Raw repo data per slug, cached on disk for GH_TTL seconds.

    With background=True, stale entries are returned as-is and refreshed
    in a thread, so the page never waits on GitHub unless asked to.
    """
    if background and not refresh:
        cache = read_gh_cache()
        now = time.time()
        if all(s in cache for s in slugs):
            if any(now - cache[s]["at"] > GH_TTL for s in slugs) and not _gh_lock.locked():
                threading.Thread(target=github_all, args=(slugs,), daemon=True).start()
            return {s: cache[s] for s in slugs}
    with _gh_lock:
        cache = read_gh_cache()
        now = time.time()
        stale = [s for s in slugs if refresh or now - cache.get(s, {}).get("at", 0) > GH_TTL]
        if stale:
            with ThreadPoolExecutor(8) as pool:
                for slug, data in zip(stale, pool.map(fetch_github, stale)):
                    if "error" in data and slug in cache:
                        continue  # keep the last good copy
                    cache[slug] = {"at": now, "data": data}
            os.makedirs(os.path.dirname(GH_CACHE), exist_ok=True)
            with open(GH_CACHE, "w", encoding="utf-8") as f:
                json.dump(cache, f)
        return {s: cache[s] for s in slugs if s in cache}


def weeks_ago(d):
    return (date.today() - d).days // 7


def summarize_github(raw):
    if not raw or "error" in raw:
        return {"error": (raw or {}).get("error", "unavailable")}
    milestones = []
    for m in raw["milestones"]["nodes"]:
        opened, closed = m["open"]["totalCount"], m["closed"]["totalCount"]
        total = opened + closed
        if total == 0 and m["state"] == "CLOSED":
            continue
        milestones.append({"number": m["number"], "title": m["title"], "url": m["url"],
                           "due": m["dueOn"], "open": opened, "closed": closed, "total": total,
                           "done": m["state"] == "CLOSED" or (total > 0 and opened == 0)})
    if milestones and all(m["due"] for m in milestones):
        milestones.sort(key=lambda m: m["due"])
    current = next((m for m in milestones if not m["done"] and m["total"]), None)

    issues = []
    for i in raw["openIssues"]["nodes"]:
        labels = [l["name"] for l in i["labels"]["nodes"]]
        prio = next((int(PRIORITY.match(l)[1]) for l in labels if PRIORITY.match(l)), 9)
        issues.append({"number": i["number"], "title": i["title"], "url": i["url"],
                       "updated": i["updatedAt"], "labels": labels,
                       "milestone": (i["milestone"] or {}).get("number"),
                       "blocked": any(BLOCKED.search(l) for l in labels),
                       "decision": any(DECISION.search(l) for l in labels),
                       "doing": any(DOING.search(l) for l in labels), "priority": prio})
    issues.sort(key=lambda i: i["updated"], reverse=True)
    issues.sort(key=lambda i: (not i["blocked"], not i["doing"], i["priority"]))

    if current:
        left = [i for i in issues if i["milestone"] == current["number"]]
    elif not milestones:
        left = issues
    else:
        left = []

    closed_weekly = [0] * WEEKS
    last_closed = None
    for i in raw["closedIssues"]["nodes"]:
        if i["closedAt"]:
            w = weeks_ago(datetime.fromisoformat(i["closedAt"].replace("Z", "+00:00")).date())
            if w < WEEKS:
                closed_weekly[WEEKS - 1 - w] += 1
            if i.get("title") and (last_closed is None or i["closedAt"] > last_closed["closedAt"]):
                last_closed = i

    opened, closed = raw["openIssues"]["totalCount"], raw["closedIssues"]["totalCount"]
    tracked = [m for m in milestones if m["total"]]
    if tracked:
        done_n, total_n = sum(m["closed"] for m in tracked), sum(m["total"] for m in tracked)
    else:
        done_n, total_n = closed, opened + closed
    return {
        "source": "github", "url": raw["url"], "milestones": milestones,
        "current": current["number"] if current else None,
        "progress": round(100 * done_n / total_n) if total_n else None,
        "done": done_n, "total": total_n, "open": opened, "closed": closed,
        "left": left[:40], "leftCount": len(left),
        "blockers": [i for i in issues if i["blocked"]],
        "decisions": [i for i in issues if i["decision"] and not i["blocked"]],
        "doing": sum(i["doing"] for i in issues),
        "closedWeekly": closed_weekly,
        "lastClosed": {"label": f"#{last_closed['number']} {last_closed['title']}", "url": last_closed["url"],
                       "date": last_closed["closedAt"][:10]} if last_closed else None,
    }


# ---------- roadmap files ----------
# For projects without GitHub issues: a markdown checklist in the repo.
# Headings are milestones, `- [ ]` / `- [x]` items are tasks.

ROADMAP_FILES = ("ROADMAP.md", "TODO.md", "docs/ROADMAP.md", "docs/TODO.md")
CHECKBOX = re.compile(r"^\s*[-*+]\s+\[([ xX])\]\s+(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")


def roadmap_file(p):
    """Relative path of the project's roadmap: the configured one, else the first conventional file."""
    if p.get("roadmap"):
        return p["roadmap"] if os.path.isfile(os.path.join(p["path"], p["roadmap"])) else None
    # Match names case-insensitively so Linux finds roadmap.md / Todo.md like macOS and Windows do.
    for want in ROADMAP_FILES:
        folder, _, name = want.rpartition("/")
        try:
            hit = next(f for f in os.listdir(os.path.join(p["path"], folder)) if f.lower() == name.lower())
        except (OSError, StopIteration):
            continue
        rel = f"{folder}/{hit}" if folder else hit
        if os.path.isfile(os.path.join(p["path"], rel)):
            return rel
    return None


def clean_md(text):
    return re.sub(r"\*\*|__|`", "", text).strip()


def parse_roadmap(text):
    """[(milestone title, [task, ...]), ...] in file order."""
    heads, items, h1s, fence = [], [], 0, False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        h = HEADING.match(line)
        if h:
            level = len(h[1])
            h1s += level == 1
            while heads and heads[-1][0] >= level:
                heads.pop()
            heads.append((level, clean_md(h[2])))
            continue
        c = CHECKBOX.match(line)
        if c:
            items.append((tuple(heads), {"line": n, "text": clean_md(c[2]), "done": c[1] != " "}))
    # Milestones live at the shallowest heading level that holds tasks (skipping a lone H1 title).
    levels = {level for path, _ in items for level, _ in path}
    if h1s == 1 and len(levels) > 1:
        levels.discard(1)
    top = min(levels) if levels else None
    groups = {}
    for path, task in items:
        title = next((t for level, t in path if level == top), None) or (path[-1][1] if path else "Tasks")
        groups.setdefault(title, []).append(task)
    return list(groups.items())


def summarize_roadmap(path, rel):
    try:
        with open(os.path.join(path, rel), encoding="utf-8") as f:
            groups = parse_roadmap(f.read())
    except (OSError, UnicodeDecodeError):
        return None
    if not groups:
        return None
    milestones = []
    for i, (title, tasks) in enumerate(groups, 1):
        closed = sum(t["done"] for t in tasks)
        milestones.append({"number": i, "title": title, "url": None, "due": None, "open": len(tasks) - closed,
                           "closed": closed, "total": len(tasks), "done": closed == len(tasks)})
    current = next((m for m in milestones if not m["done"]), None)
    left = [{"number": None, "title": t["text"], "url": None, "line": t["line"], "labels": [],
             "blocked": False, "decision": False, "doing": False}
            for t in (groups[current["number"] - 1][1] if current else []) if not t["done"]]

    # Tasks ticked per week, read from the file's git history.
    closed_weekly, last_closed, day = [0] * WEEKS, None, None
    for line in git(path, "log", f"--since={WEEKS * 7} days ago", "--format=pm-commit %cs", "-p", "--unified=0", "--", rel).splitlines():
        if line.startswith("pm-commit "):
            day = date.fromisoformat(line[10:])
        elif day and line.startswith("+") and not line.startswith("+++"):
            c = CHECKBOX.match(line[1:])
            if c and c[1] != " ":
                w = weeks_ago(day)
                if w < WEEKS:
                    closed_weekly[WEEKS - 1 - w] += 1
                last_closed = last_closed or {"label": clean_md(c[2]), "url": None, "date": day.isoformat()}

    done_n, total_n = sum(m["closed"] for m in milestones), sum(m["total"] for m in milestones)
    return {
        "source": "roadmap", "file": rel, "url": None, "milestones": milestones,
        "current": current["number"] if current else None,
        "progress": round(100 * done_n / total_n), "done": done_n, "total": total_n,
        "open": total_n - done_n, "closed": done_n,
        "left": left[:40], "leftCount": len(left), "blockers": [], "decisions": [], "doing": 0,
        "closedWeekly": closed_weekly, "lastClosed": last_closed,
        "edited": git(path, "log", "-1", "--format=%cs", "--", rel) or None,
    }


def toggle_task(name, line, text, done):
    db = load()
    p = db["projects"].get(name)
    rel = roadmap_file(p) if p else None
    if not rel:
        return 404, {"error": "This project has no roadmap file."}
    file = os.path.join(p["path"], rel)
    with open(file, encoding="utf-8", newline="") as f:
        lines = f.read().splitlines(keepends=True)
    c = CHECKBOX.match(lines[line - 1].rstrip("\r\n")) if 0 < line <= len(lines) else None
    if not c or clean_md(c[2]) != text:
        return 409, {"error": f"{rel} changed since the board loaded. Refresh and try again."}
    lines[line - 1] = re.sub(r"\[[ xX]\]", "[x]" if done else "[ ]", lines[line - 1], count=1)
    with open(file, "w", encoding="utf-8", newline="") as f:
        f.writelines(lines)
    log(p, f"{'done' if done else 'reopened'}: {text}")
    save(db)
    return 200, {"ok": True}


# ---------- web ----------

def health(days):
    if days is None:
        return "unknown"
    return "active" if days <= ACTIVE_DAYS else "cooling" if days <= COOLING_DAYS else "stalled"


def local_detail(path):
    info = activity(path)
    days = idle_days(info)
    weekly = [0] * WEEKS
    for d in git(path, "log", f"--since={WEEKS * 7} days ago", "--format=%cs").splitlines():
        w = weeks_ago(date.fromisoformat(d))
        if w < WEEKS:
            weekly[WEEKS - 1 - w] += 1
    commits = [dict(zip(("date", "subject"), l.split("|", 1)))
               for l in git(path, "log", "-6", "--format=%cs|%s").splitlines()]
    return {"last": info["last"].isoformat() if info["last"] else None, "idle": days,
            "health": health(days), "dirty": info["dirty"], "commits": info["commits"],
            "weekly": weekly, "recent": commits, "slug": github_slug(path)}


def board(refresh=False):
    db = load()
    sync(db, quiet=True)
    save(db)
    projects = {n: p for n, p in db["projects"].items() if os.path.exists(p["path"])}
    def scan(n):
        p = projects[n]
        rel = roadmap_file(p)
        return local_detail(p["path"]), summarize_roadmap(p["path"], rel) if rel else None

    with ThreadPoolExecutor(8) as pool:
        scanned = dict(zip(projects, pool.map(scan, projects)))
    gh = github_all(sorted({l["slug"] for l, _ in scanned.values() if l["slug"]}), refresh, background=True)
    out = []
    for n, p in projects.items():
        l, roadmap = scanned[n]
        entry = gh.get(l["slug"]) if l["slug"] else None
        github = summarize_github(entry["data"]) if entry else None
        # GitHub issues win, unless a roadmap file was chosen explicitly or there are no issues.
        use_roadmap = roadmap and (p.get("roadmap") or not github or github.get("error") or not github["total"])
        out.append({"name": n, "path": p["path"], "displayPath": tilde(p["path"]), "status": p["status"], "focus": bool(p.get("focus")),
                    "next": p.get("next", ""), "why": p.get("why", ""), "blocker": p.get("blocker", ""),
                    "leftoff": p.get("leftoff", ""), "log": p.get("log", [])[-10:], "local": l,
                    "tracker": roadmap if use_roadmap else github,
                    "repoUrl": (entry["data"].get("url") if entry else None),
                    "fetchedAt": entry["at"] if entry else None})
    weeks = [(date.today() - timedelta(days=7 * (WEEKS - 1 - i))).isoformat() for i in range(WEEKS)]
    ideas = {"cooldown": db["idea_cooldown_days"],
             "waiting": [idea_view(db, i) for i in db["ideas"] if i["status"] == "waiting"],
             "letGo": sum(i["status"] == "dropped" for i in db["ideas"]),
             "started": sum(i["status"] == "started" for i in db["ideas"])}
    return {"today": today(), "focusLimit": db["focus_limit"], "weeks": weeks, "projects": out, "ideas": ideas}


def idea_action(iid, body):
    db = load()
    try:
        if iid is None:
            idea = add_idea(db, str(body.get("title", "")), str(body.get("pitch", "")))
            result = {"ok": True, "id": idea["id"]}
        elif body.get("action") == "start":
            name, path, created = start_idea(db, iid, body.get("path"))
            result = {"ok": True, "project": name, "created": created}
        elif body.get("action") == "drop":
            drop_idea(db, iid, str(body.get("note", "")))
            result = {"ok": True}
        else:
            return 400, {"error": "unknown action"}
    except ValueError as e:
        return 409, {"error": str(e)}
    except OSError as e:
        return 500, {"error": f"Couldn't create the project folder: {e.strerror}"}
    save(db)
    return 200, result


EDITABLE = ("next", "why", "blocker", "leftoff")


def update_project(name, changes):
    db = load()
    if name not in db["projects"]:
        return 404, {"error": f"No project named {name}"}
    p = db["projects"][name]
    if "focus" in changes:
        if changes["focus"]:
            err = try_focus(db, name)
            if err:
                return 409, {"error": err}
        elif p.get("focus"):
            p["focus"] = False
            log(p, "unfocused")
    if changes.get("status") in STATUSES and changes["status"] != p["status"]:
        p["status"] = changes["status"]
        if p["status"] != "active":
            p["focus"] = False
        log(p, p["status"])
    for field in EDITABLE:
        if field in changes and str(changes[field]).strip() != p.get(field, ""):
            p[field] = str(changes[field]).strip()
            log(p, f"{field}: {p[field]}" if p[field] else f"{field} cleared")
    if str(changes.get("note", "")).strip():
        log(p, str(changes["note"]).strip())
    save(db)
    return 200, {"ok": True}


def cmd_serve(db, args):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import webbrowser

    port = next((int(a) for a in args if a.isdigit()), DEFAULT_PORT)
    if "--log" in args and args.index("--log") + 1 < len(args):
        # Autostart runs headless: send output to a log file instead of nowhere.
        sys.stdout = sys.stderr = open(args[args.index("--log") + 1], "a", encoding="utf-8", buffering=1)
    allowed = {f"127.0.0.1:{port}", f"localhost:{port}"}
    types = {".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml"}
    write_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body, ctype="application/json"):
            data = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype + "; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def trusted(self):
            # Only answer this machine, under our own hostname (blocks DNS rebinding & CSRF).
            if self.headers.get("Host") not in allowed:
                return False
            origin = self.headers.get("Origin")
            return origin is None or urlparse(origin).netloc in allowed

        def do_GET(self):
            if not self.trusted():
                return self.send(403, {"error": "forbidden"})
            url = urlparse(self.path)
            if url.path == "/api/board":
                return self.send(200, board(refresh="refresh" in parse_qs(url.query)))
            name = "index.html" if url.path == "/" else os.path.basename(url.path)
            file = os.path.join(WEB, name)
            if not os.path.isfile(file):
                return self.send(404, {"error": "not found"})
            with open(file, "rb") as f:
                self.send(200, f.read(), types.get(os.path.splitext(name)[1], "application/octet-stream"))

        def do_POST(self):
            if not self.trusted() or self.headers.get("Content-Type") != "application/json":
                return self.send(403, {"error": "forbidden"})
            path = urlparse(self.path).path
            m = re.fullmatch(r"/api/projects/([^/]+)(/task)?", path)
            idea = re.fullmatch(r"/api/ideas(?:/(\d+))?", path)
            if not m and not idea:
                return self.send(404, {"error": "not found"})
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                if m and m[2]:
                    task = (int(body["line"]), str(body["text"]), bool(body["done"]))
            except (ValueError, KeyError, TypeError, AttributeError):
                return self.send(400, {"error": "bad request"})
            with write_lock:
                if idea:
                    self.send(*idea_action(idea[1], body))
                elif m[2]:
                    self.send(*toggle_task(unquote(m[1]), *task))
                else:
                    self.send(*update_project(unquote(m[1]), body))

    url = f"http://localhost:{port}"
    try:
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError:
        sys.exit(f"Port {port} is already in use. If pm is already running, open {url}")
    print(f"{datetime.now():%Y-%m-%d %H:%M}  pm board at {col(url, 'c')}  (Ctrl+C to stop)")
    if "--no-open" not in args:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()


# ---------- autostart ----------
# Start `pm serve` at login using each OS's own mechanism; no admin rights needed.

DEFAULT_PORT = 4242
AUTOSTART_ID = "dev.pm.board"
SCRIPT = os.path.realpath(__file__)


def autostart_target():
    """Where the login item lives on this OS: (kind, path)."""
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return "launchd", os.path.join(home, "Library", "LaunchAgents", f"{AUTOSTART_ID}.plist")
    if os.name == "nt":
        startup = os.path.join(os.environ.get("APPDATA", home), "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
        return "startup", os.path.join(startup, "pm-board.vbs")
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
    has_systemd = bool(shutil.which("systemctl")) and subprocess.run(
        ["systemctl", "--user", "show-environment"], capture_output=True).returncode == 0
    if has_systemd:
        return "systemd", os.path.join(config, "systemd", "user", "pm-board.service")
    return "xdg", os.path.join(config, "autostart", "pm-board.desktop")


def log_path():
    if sys.platform == "darwin":
        return os.path.join(os.path.expanduser("~"), "Library", "Logs", "pm-board.log")
    return os.path.join(HERE, ".cache", "pm-board.log")


def board_running(port):
    import socket
    with socket.socket() as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def autostart_on(port):
    kind, path = autostart_target()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    os.makedirs(os.path.dirname(log_path()), exist_ok=True)
    py, log = sys.executable, log_path()
    serve = [SCRIPT, "serve", str(port), "--no-open"]

    if kind == "launchd":
        import plistlib
        with open(path, "wb") as f:
            plistlib.dump({
                "Label": AUTOSTART_ID, "ProgramArguments": [py, *serve], "RunAtLoad": True,
                # Login items get a bare PATH; keep ours so git and gh are found.
                "EnvironmentVariables": {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "PYTHONUNBUFFERED": "1"},
                "StandardOutPath": log, "StandardErrorPath": log,
            }, f)
        domain = f"gui/{os.getuid()}"
        subprocess.run(["launchctl", "bootout", f"{domain}/{AUTOSTART_ID}"], capture_output=True)
        subprocess.run(["launchctl", "bootstrap", domain, path], capture_output=True)
    elif kind == "systemd":
        quote = lambda s: '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
        with open(path, "w", encoding="utf-8") as f:
            f.write("[Unit]\nDescription=pm project board\n\n[Service]\n"
                    f"ExecStart={' '.join(quote(a) for a in [py, *serve])}\n"
                    f"Environment={quote('PATH=' + os.environ.get('PATH', '/usr/bin:/bin'))} PYTHONUNBUFFERED=1\n"
                    "Restart=on-failure\nRestartSec=30\n\n[Install]\nWantedBy=default.target\n")
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "--user", "enable", "--now", "pm-board.service"], capture_output=True)
    elif kind == "xdg":
        import shlex
        with open(path, "w", encoding="utf-8") as f:
            f.write("[Desktop Entry]\nType=Application\nName=pm board\nNoDisplay=true\n"
                    f"Exec={shlex.join([py, *serve, '--log', log])}\nX-GNOME-Autostart-enabled=true\n")
        if not board_running(port):
            subprocess.Popen([py, *serve, "--log", log], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:  # Windows: a hidden launcher in the Startup folder, running pythonw (no console window)
        pyw = os.path.join(os.path.dirname(py), "pythonw.exe")
        pyw = pyw if os.path.exists(pyw) else py
        cmd = " ".join(f'""{a}""' for a in [pyw, *serve, "--log", log])
        with open(path, "w", encoding="utf-8") as f:
            f.write(f'CreateObject("WScript.Shell").Run "{cmd}", 0, False\n')
        if not board_running(port):
            subprocess.Popen([pyw, *serve, "--log", log], creationflags=0x08000000,  # CREATE_NO_WINDOW
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return kind, path


def autostart_off():
    kind, path = autostart_target()
    if kind == "launchd":
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{AUTOSTART_ID}"], capture_output=True)
    elif kind == "systemd":
        subprocess.run(["systemctl", "--user", "disable", "--now", "pm-board.service"], capture_output=True)
    existed = os.path.exists(path)
    if existed:
        os.remove(path)
    if kind == "systemd":
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
    return kind, path, existed


def autostart_port(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            m = re.search(r"serve\D{0,30}(\d+)", f.read())
        return int(m[1]) if m else DEFAULT_PORT
    except OSError:
        return DEFAULT_PORT


def cmd_autostart(db, args):
    action = args[0] if args else "status"
    port = next((int(a) for a in args[1:] if a.isdigit()), DEFAULT_PORT)
    names = {"launchd": "macOS LaunchAgent", "systemd": "systemd user service",
             "xdg": "desktop autostart entry", "startup": "Windows Startup folder"}
    if action == "on":
        was_running = board_running(port)
        kind, path = autostart_on(port)
        print(col(f"✓ The board now starts at login", "g") + f" ({names[kind]}).")
        print(col(f"  {tilde(path)}", "dim"))
        time.sleep(1.5)
        if board_running(port):
            print(f"  Open http://localhost:{port}, and bookmark it." +
                  (col("\n  (A board was already running on this port; the login item takes over from next login.)", "dim")
                   if was_running else ""))
        else:
            print(col(f"  It didn't come up yet; check the log: {tilde(log_path())}", "y"))
    elif action == "off":
        kind, path, existed = autostart_off()
        print(f"Autostart is off ({names[kind]} removed)." if existed else "Autostart wasn't on.")
        if existed and kind in ("xdg", "startup") and board_running(port):
            print(col("  The board that's running now stops when you log out.", "dim"))
    elif action == "status":
        kind, path = autostart_target()
        on = os.path.exists(path)
        p = autostart_port(path) if on else port
        print(f"Autostart: {col('on', 'g') if on else col('off', 'dim')}  ({names[kind]}{', ' + tilde(path) if on else ''})")
        print(f"Board:     {col(f'running at http://localhost:{p}', 'g') if board_running(p) else col('not running', 'dim')}")
        if on:
            print(col(f"Log:       {tilde(log_path())}", "dim"))
        else:
            print(col("Turn it on with: pm autostart on", "dim"))
    else:
        sys.exit("usage: pm autostart [on [port] | off | status]")


HELP = """pm — keep your projects from quietly dying

  pm                      the board: focus, in motion, stalled
  pm serve [port]         the web board (default http://localhost:4242)
  pm autostart [on|off]   start the web board at login (macOS, Linux, Windows)
  pm review               triage stalled projects one by one (do this weekly)
  pm idea "..." ["why"]   park a new project idea; it can start after a 7-day cooldown
  pm ideas [--all]        the idea inbox
  pm idea start <id> [path]  ready idea → new repo + ROADMAP.md, in focus (needs a free slot)
  pm idea drop <id> [note]   let an idea go
  pm focus <name>         put a project in focus (max 3)
  pm unfocus <name>
  pm next <name> "..."    the very next concrete step — makes resuming easy
  pm why <name> "..."     why this project matters to you
  pm block <name> "..."   what's stopping you (GitHub issues labeled `blocked` count too)
  pm unblock <name>
  pm leftoff <name> "..." where you left off: what was in your head
  pm roadmap <name> [file] track progress from a markdown checklist instead of
                          GitHub issues (default: ROADMAP.md, TODO.md, docs/roadmap.md)
  pm note <name> "..."    journal entry
  pm park|drop|done <name> [note]
  pm revive <name>        back to active
  pm show <name>          details, recent commits, journal
  pm list [status]        everything, grouped by status
  pm add <path> [name]    track a folder that isn't auto-discovered
  pm root <dir>           add a folder to scan
  pm ignore <name>        stop tracking something

Names can be abbreviated: `pm show grim`."""

COMMANDS = {
    "status": cmd_status, "review": cmd_review, "focus": cmd_focus, "unfocus": cmd_unfocus,
    "next": cmd_text("next", "next"), "why": cmd_text("why", "why"), "note": cmd_note,
    "block": cmd_text("blocker", "blocker"), "unblock": cmd_unblock, "serve": cmd_serve,
    "roadmap": cmd_roadmap, "leftoff": cmd_text("leftoff", "left off"),
    "idea": cmd_idea, "ideas": cmd_ideas, "autostart": cmd_autostart,
    "park": set_status("parked", "park"), "drop": set_status("dropped", "drop"),
    "done": set_status("done", "done"), "revive": set_status("active", "revive"),
    "show": cmd_show, "list": cmd_list, "add": cmd_add, "root": cmd_root, "ignore": cmd_ignore,
}
DB_REF = [None]


def main():
    # Under a non-UTF-8 locale, POSIX hands us undecodable bytes as surrogates; recover them as UTF-8.
    args = [os.fsencode(a).decode("utf-8", "replace") if os.name != "nt" else a for a in sys.argv[1:]]
    if args and args[0] in ("-h", "--help", "help"):
        print(HELP)
        return
    cmd = args[0] if args else "status"
    if cmd not in COMMANDS:
        sys.exit(f"Unknown command '{cmd}'.\n\n{HELP}")
    db = load()
    DB_REF[0] = db
    COMMANDS[cmd](db, args[1:])


if __name__ == "__main__":
    main()
