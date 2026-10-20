'use strict';

const $ = (sel, el = document) => el.querySelector(sel);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const css = (name) => `var(--${name})`;

// Browser storage can be missing or blocked; the view choice is only a convenience.
const stored = (key) => { try { return localStorage.getItem(key); } catch { return null; } };

const state = {
  data: null, filter: '', open: null, tab: 'all', view: stored('pm-view') || 'board', editing: null, expanded: null,
  collapsed: { parked: true, archived: true }, suggest: false, skipped: [],
  startingIdea: null, droppingIdea: null, refocusIdea: false,
};

// ---------- data ----------

async function load(refresh = false) {
  const btn = $('#refresh');
  btn.disabled = true;
  if (refresh) btn.textContent = 'Syncing…';
  try {
    const res = await fetch('/api/board' + (refresh ? '?refresh=1' : ''));
    if (!res.ok) throw new Error(res.statusText);
    state.data = await res.json();
    render();
  } catch {
    toast('Could not reach pm. Is `pm serve` still running?', true);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Sync GitHub';
  }
}

// POST JSON; returns the response body, or null after showing the error.
async function postJson(path, body) {
  try {
    const res = await fetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const data = await res.json();
    if (!res.ok) return toast(data.error || 'Save failed', true), null;
    return data;
  } catch {
    return toast('Save failed: pm serve is not reachable', true), null;
  }
}

const post = async (path, body) => !!(await postJson(path, body));

async function update(name, changes, okMsg) {
  const ok = await post('/api/projects/' + encodeURIComponent(name), changes);
  if (!ok) return false;
  await load();
  if (okMsg) toast(okMsg);
  return true;
}

function derive(p) {
  const t = p.tracker;
  const g = t && !t.error ? t : null;
  const roadmap = !!g && g.source === 'roadmap';
  const unit = roadmap ? 'task' : 'issue';
  const cur = (g && g.milestones.find((m) => m.number === g.current)) || null;
  const hasRoadmap = !!g && g.milestones.some((m) => m.total);
  const blockers = (g ? g.blockers.length : 0) + (p.blocker ? 1 : 0);
  const section = p.status === 'parked' ? 'parked'
    : p.status === 'done' ? 'done'
    : p.status !== 'active' ? 'archived'
    : p.focus ? 'focus'
    : p.local.health === 'stalled' || p.local.health === 'unknown' ? 'stalled'
    : 'motion';

  // What the "current milestone" column shows.
  const source = roadmap ? ` · ${g.file}` : '';
  let ms;
  if (t && t.error) ms = { none: "Couldn't load GitHub issues" };
  else if (!g && !p.local.slug) ms = { none: 'Local only · no roadmap file' };
  else if (!g) ms = { none: 'Syncing…' };
  else if (!g.total) ms = { none: `No issues yet${p.local.commits > 5 ? ` · ${p.local.commits} commits` : ''}`, link: `${g.url}/issues/new` };
  else if (hasRoadmap && !cur) ms = { title: 'All milestones done ✓', pct: 100, meta: `${g.done}/${g.total} · roadmap complete${source}` };
  else if (cur) {
    const pct = Math.round((100 * cur.closed) / cur.total);
    ms = { title: cur.title, pct, left: cur.open, meta: roadmap
      ? `${cur.closed}/${cur.total} · ${cur.open} left${source}`
      : `${cur.closed}/${cur.total} · ${cur.open} left · roadmap ${g.progress}%` };
  } else {
    ms = { title: 'All issues', pct: g.progress, left: g.open, meta: `${g.closed}/${g.total} · ${g.open} left · no milestones` };
  }
  return { g, roadmap, unit, cur, hasRoadmap, blockers, section, ms };
}

// "Pick for me": close-to-done milestones first, then momentum, then waiting decisions.
function suggestion(p, d) {
  const recent = p.local.weekly.slice(-4).reduce((a, b) => a + b, 0);
  const left = d.ms.left || 0, pct = d.ms.pct || 0;
  const decisions = d.g ? d.g.decisions.length : 0;
  const stalled = d.section === 'stalled';
  const close = left > 0 && left <= 3;
  // Momentum is capped so a burst of commits can't drown out a nearly finished milestone.
  const score = (close ? 6 - left : 0) + pct / 50 + Math.min(recent, 24) / 6 + (decisions ? 1 : 0) - (stalled ? 1.5 : 0) - (d.g ? 0 : 1);
  const reason = close ? `${plural(left, d.unit)} from closing ${d.ms.title}${stalled ? ' — a quick revive' : ''}`
    : recent >= 8 ? `${recent} commits in the last 4 weeks — ride the momentum`
    : decisions ? `${plural(decisions, 'decision')} waiting on you`
    : d.g && d.g.progress >= 50 ? `Roadmap ${d.g.progress}% done`
    : `Active ${ago(p.local.idle)}`;
  return { score, reason };
}

// ---------- formatting ----------

function ago(days) {
  if (days == null) return 'never';
  if (days === 0) return 'today';
  if (days === 1) return 'yesterday';
  if (days < 14) return `${days}d ago`;
  if (days < 60) return `${Math.floor(days / 7)}w ago`;
  return `${Math.floor(days / 30)}mo ago`;
}

const fmtDay = (iso) => new Date(iso + 'T00:00').toLocaleDateString(undefined, { month: 'short', day: 'numeric' });

function weekRange(i) {
  const end = new Date(state.data.weeks[i] + 'T00:00');
  const start = new Date(end);
  start.setDate(end.getDate() - 6);
  const f = (d) => d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  return `${f(start)} – ${f(end)}`;
}

// ---------- pieces ----------

function meter(pct, label) {
  return `<div class="meter" role="meter" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}" aria-label="${esc(label)}"><i style="width:${pct}%"></i></div>`;
}

// Weekly bars: zero weeks sit as a 2px stub, the current week is the accent.
function bars(values, height, color, tipFor) {
  const max = Math.max(1, ...values);
  return values.map((v, i) => {
    const h = Math.max(2, Math.round((v / max) * height));
    const bg = v === 0 ? css('track') : i === values.length - 1 ? css('blue') : color;
    return `<span style="height:${h}px;background:${bg}" data-tip="${esc(tipFor(v, i))}"></span>`;
  }).join('');
}

function commitTip(p) {
  const d = derive(p);
  const closed = d.g ? d.g.closedWeekly : null;
  return (v, i) => `${weekRange(i)}: ${plural(v, 'commit')}${closed ? `, ${plural(closed[i], d.unit)} closed` : ''}`;
}

const SECTION_DOT = { motion: 'green', focus: 'green', stalled: 'amber', done: 'green', parked: 'dim-dot', archived: 'dim-dot' };

function msBlock(d) {
  const { ms } = d;
  if (ms.none) {
    return `<span class="ms-none">${esc(ms.none)}${ms.link ? ` · <a href="${esc(ms.link)}" target="_blank" rel="noopener">create one</a>` : ''}</span>`;
  }
  return `<div class="ms">
    <div class="line"><span title="${esc(ms.title)}">${esc(ms.title)}</span><span class="mono">${ms.pct}%</span></div>
    ${meter(ms.pct, ms.title)}
    <span class="meta">${esc(ms.meta)}</span>
  </div>`;
}

// ---------- top tiles ----------

function tiles(projects) {
  const weeks = state.data.weeks.length;
  const closedBy = Array(weeks).fill(0);
  for (const p of projects) {
    const t = p.tracker;
    if (t && !t.error && t.source === 'github') t.closedWeekly.forEach((v, i) => (closedBy[i] += v));
  }
  const thisWeek = closedBy[weeks - 1], delta = thisWeek - closedBy[weeks - 2];

  const ds = projects.map((p) => [p, derive(p)]);
  const count = (s) => ds.filter(([, d]) => d.section === s).length;
  const focus = count('focus'), motion = count('motion'), stalled = count('stalled');
  const active = focus + motion + stalled || 1;
  const blocked = ds.filter(([p, d]) => p.status === 'active' && d.blockers).length;
  const w = (n) => `${(100 * n) / active}%`;

  const almost = ds
    .filter(([p, d]) => p.status === 'active' && d.ms.left > 0 && d.ms.left <= 3 && d.ms.pct >= 50 && d.ms.title)
    .sort((a, b) => a[1].ms.left - b[1].ms.left || b[1].ms.pct - a[1].ms.pct)
    .slice(0, 3);

  const legend = [
    ['Focus', `${focus}/${state.data.focusLimit}`, 'blue', 'focus'],
    ['In motion', motion, 'green', 'motion'],
    ['Stalled', stalled, 'amber', 'stalled'],
    ['Blocked', blocked, 'red', null],
  ];

  return `<section class="tiles" aria-label="Summary">
    <div class="tile hero">
      <div>
        <div class="tile-label">Issues closed this week</div>
        <div class="hero-num">${thisWeek}</div>
        <div class="delta${delta > 0 ? ' up' : ''}">${delta === 0 ? 'Same as last week' : `${delta > 0 ? '▲' : '▼'} ${Math.abs(delta)} vs last week`}</div>
      </div>
      <div class="hero-bars">
        <div class="bars" role="img" aria-label="Issues closed per week, last 12 weeks">${bars(closedBy, 44, css('spark-hero'), (v, i) => `${weekRange(i)}: ${plural(v, 'issue')} closed`)}</div>
        <div class="cap">12 wk</div>
      </div>
    </div>

    <div class="tile mix">
      <div class="tile-label">Portfolio</div>
      <div class="stack" role="img" aria-label="${focus} in focus, ${motion} in motion, ${stalled} stalled">
        <span style="width:${w(focus)};background:${css('blue')}" data-tip="${focus} in focus"></span>
        <span style="width:${w(motion)};background:${css('green')}" data-tip="${motion} in motion"></span>
        <span style="width:${w(stalled)};background:${css('amber')}" data-tip="${stalled} stalled"></span>
      </div>
      <div class="legend">${legend.map(([label, value, color, target]) => {
        const inner = `<span class="k"><span class="dot" style="background:${css(color)}"></span>${label}</span><span class="v${value === 0 ? ' zero' : ''}">${value}</span>`;
        return target ? `<button class="plain item" data-jump="${target}">${inner}</button>` : `<div class="item" data-tip="Active projects with a blocked issue or blocker note">${inner}</div>`;
      }).join('')}</div>
    </div>

    <div class="tile almost">
      <div class="tile-head"><span>Almost there</span><span>closest milestones</span></div>
      ${almost.length ? almost.map(([p, d]) => `
        <button class="plain almost-row" data-name="${esc(p.name)}">
          <span class="line"><span class="who">${esc(p.name)} <span>· ${esc(d.ms.title)}</span></span><span class="left">${d.ms.left === 1 ? `1 ${d.unit} left` : `${d.ms.left} left`}</span></span>
          ${meter(d.ms.pct, d.ms.title)}
        </button>`).join('')
        : '<div class="almost-empty">No milestone is within 3 issues of done yet. Close a few and they\'ll show up here.</div>'}
    </div>
  </section>`;
}

// ---------- focus slots ----------

function focusBlock(projects) {
  const limit = state.data.focusLimit;
  const focused = projects.filter((p) => p.status === 'active' && p.focus)
    .sort((a, b) => (a.local.idle ?? 1e9) - (b.local.idle ?? 1e9));
  const open = Math.max(0, limit - focused.length);
  const picks = state.suggest
    ? projects
      .filter((p) => p.status === 'active' && !p.focus && !state.skipped.includes(p.name))
      .map((p) => ({ p, ...suggestion(p, derive(p)) }))
      .sort((a, b) => b.score - a.score)
      .slice(0, open)
    : [];
  if (state.suggest && !picks.length) state.suggest = false;

  const slots = [...focused.map(focusCard), ...picks.map(suggestCard)];
  while (slots.length < Math.max(limit, focused.length)) {
    slots.push(`<div class="slot empty"><span class="star-ghost" aria-hidden="true">☆</span><span>Slot ${slots.length + 1} open — star a project below</span></div>`);
  }

  let tools;
  if (state.suggest) {
    tools = `<button class="plain chip-btn solid" data-act="accept-all">Accept all</button><button class="plain chip-btn ghost" data-act="dismiss">Dismiss</button>`;
  } else {
    tools = `<span class="hint">Star the projects you actually want to move this week</span>${open ? '<button class="plain chip-btn outline" data-act="suggest">Pick for me</button>' : ''}`;
  }
  return `<section class="block" id="focus">
    <div class="block-head">
      <h2>This week's focus<span>${focused.length}/${limit}</span></h2>
      <div class="block-tools">${tools}</div>
    </div>
    <div class="slots">${slots.join('')}</div>
  </section>`;
}

function focusCard(p) {
  const d = derive(p);
  const { ms } = d;
  const progress = ms.none
    ? `<div class="ms-line"><span>${esc(ms.none)}</span></div>`
    : `<div class="d-progress"><div class="ms-line"><span>${esc(ms.title)}</span><span class="mono">${ms.pct}%</span></div>${meter(ms.pct, ms.title)}</div>`;
  return `<article class="slot" data-name="${esc(p.name)}" tabindex="0" aria-label="${esc(p.name)}, open details">
    <div class="slot-top">
      <span class="name">${esc(p.name)}</span>
      <button class="plain star-btn" data-star="${esc(p.name)}" style="color:${css('amber')}" aria-label="Remove ${esc(p.name)} from focus" data-tip="Remove from focus">★</button>
    </div>
    ${progress}
    <div class="next${p.next ? '' : ' none'}">→ ${esc(p.next || 'No next step yet')}</div>
    ${d.blockers ? `<div class="blocker">⛔ ${esc(p.blocker || plural(d.g.blockers.length, 'blocked issue'))}</div>` : ''}
  </article>`;
}

function suggestCard({ p, reason }) {
  return `<div class="slot sugg">
    <div class="slot-top">
      <span class="name">${esc(p.name)}</span>
      <span class="sugg-tag">Suggested</span>
    </div>
    <div class="sugg-reason">${esc(reason)}</div>
    <div class="sugg-actions">
      <button class="plain chip-btn blue" data-focus-it="${esc(p.name)}">Focus it</button>
      <button class="plain chip-btn ghost" data-skip="${esc(p.name)}">Skip</button>
    </div>
  </div>`;
}

// ---------- idea inbox ----------

function ideasBlock(projects) {
  const { waiting, cooldown, letGo, started } = state.data.ideas;
  const focusFull = projects.filter((p) => p.status === 'active' && p.focus).length >= state.data.focusLimit;
  const ideas = waiting.slice().sort((a, b) => a.daysLeft - b.daysLeft || a.id - b.id);
  const ready = ideas.filter((i) => i.ready).length;

  const cards = ideas.map((i) => {
    const pct = Math.min(100, Math.round((100 * i.age) / cooldown));
    let foot;
    if (state.startingIdea === i.id) {
      foot = `<div class="idea-confirm">
        <label class="ex-k" for="idea-path-${i.id}">Create the project at</label>
        <input id="idea-path-${i.id}" class="next-input" data-idea-path value="${esc(i.defaultPath)}">
        <div class="sugg-actions"><button class="plain chip-btn blue" data-idea-go="${i.id}">Create &amp; focus</button><button class="plain chip-btn ghost" data-idea-cancel>Cancel</button></div>
      </div>`;
    } else {
      const start = i.ready
        ? `<button class="plain chip-btn ${focusFull ? 'muted' : 'blue'}" data-idea-start="${i.id}" ${focusFull ? 'data-full data-tip="Focus is full. Free a slot first"' : ''}>Start it</button>` : '';
      const drop = state.droppingIdea === i.id
        ? `<button class="plain chip-btn kill" data-idea-drop="${i.id}" data-confirmed>Let it go?</button>`
        : `<button class="plain chip-btn ghost" data-idea-drop="${i.id}">Let it go</button>`;
      foot = `<div class="idea-foot"><span class="ex-k">Parked ${ago(i.age)}</span><div class="sugg-actions">${start}${drop}</div></div>`;
    }
    return `<div class="idea${i.ready ? ' ready' : ''}">
      <div class="slot-top">
        <span class="name">${esc(i.title)}</span>
        <span class="idea-when">${i.ready ? `<span class="dot" style="background:${css('green')}"></span>Ready` : `<span class="mono">${i.daysLeft}d</span> to go`}</span>
      </div>
      ${i.pitch ? `<div class="sugg-reason">${esc(i.pitch)}</div>` : ''}
      ${meter(pct, i.ready ? 'Cooldown done' : `Cooldown ${i.age} of ${cooldown} days`)}
      ${foot}
    </div>`;
  });

  return `<section class="block" id="ideas">
    <div class="block-head">
      <h2>Idea inbox<span>${ideas.length}${ready ? ` · ${ready} ready` : ''}</span></h2>
      <span class="hint">New ideas wait ${cooldown} days before they can become a project${started ? ` · ${started} started so far` : ''}</span>
    </div>
    <form class="idea-add" data-idea-form>
      <input name="title" placeholder="New project idea? Park it here instead of starting it" aria-label="Idea" autocomplete="off" required>
      <input name="pitch" placeholder="Why it's exciting (optional)" aria-label="Why it's exciting" autocomplete="off">
      <button class="btn">Park idea</button>
    </form>
    ${cards.length ? `<div class="idea-grid">${cards.join('')}</div>` : ''}
    ${letGo ? `<p class="idea-note">${plural(letGo, 'idea')} let go so far: ${letGo === 1 ? 'a project' : `${letGo} projects`} you never had to abandon.</p>` : ''}
  </section>`;
}

// ---------- table ----------

const GROUPS = {
  motion: ['In motion', 'green', 'touched in the last 3 weeks'],
  stalled: ['Stalled', 'amber', 'no activity for 3+ weeks — revive, park or kill'],
  done: ['Done', 'green', 'finished — the ones that made it'],
  parked: ['Parked', 'faint', 'set aside on purpose'],
  archived: ['Killed', 'dim-dot', 'let go on purpose — restore anytime'],
};

function nextCell(p, d) {
  if (d.section === 'stalled') {
    return `<div class="triage">
      <button class="plain tri revive" data-revive="${esc(p.name)}" data-tip="Move back into focus">Revive</button>
      <button class="plain tri park" data-status="parked" data-who="${esc(p.name)}" data-tip="Set aside on purpose">Park</button>
      <button class="plain tri kill" data-status="dropped" data-who="${esc(p.name)}" data-tip="Archive for good">Kill</button>
    </div>`;
  }
  if (d.section === 'done') {
    // Projects marked done before pm recorded the day fall back to their last commit.
    const when = p.finished ? fmtDay(p.finished) : p.local.last ? fmtDay(p.local.last.slice(0, 10)) : null;
    return `<div class="triage">
      <span class="finished">✓ Finished${when ? ` ${esc(when)}` : ''}</span>
      <button class="plain tri park" data-status="active" data-who="${esc(p.name)}" data-tip="Back on the active list">↺ Reopen</button>
    </div>`;
  }
  if (d.section === 'parked' || d.section === 'archived') {
    return `<button class="plain tri park" data-status="active" data-who="${esc(p.name)}">↺ Restore</button>`;
  }
  if (state.editing === p.name) {
    return `<input class="next-input" data-edit="${esc(p.name)}" value="${esc(p.next)}" placeholder="Smallest next action…" aria-label="Next step for ${esc(p.name)}">`;
  }
  if (p.next) return `<button class="plain next-text" data-editbtn="${esc(p.name)}" title="Click to edit">→ ${esc(p.next)}</button>`;
  return `<button class="plain next-add" data-editbtn="${esc(p.name)}">+ Add next step</button>`;
}

function expandPanel(p, d) {
  const commit = p.local.recent[0];
  const lc = d.g && d.g.lastClosed;
  const lcLabel = lc ? (lc.url ? `<a href="${esc(lc.url)}" target="_blank" rel="noopener">${esc(lc.label)}</a>` : esc(lc.label)) : '—';
  return `<div class="expand">
    <div class="ex-col">
      <span class="ex-k">Last commit · ${ago(p.local.idle)}</span>
      <span class="ex-v mono">${esc(commit ? commit.subject : '—')}</span>
    </div>
    <div class="ex-col">
      <span class="ex-k">${d.roadmap ? 'Last checked task' : 'Last closed issue'}${lc ? ` · ${esc(fmtDay(lc.date))}` : ''}</span>
      <span class="ex-v">${lcLabel}</span>
    </div>
    <div class="ex-col">
      <span class="ex-k">Where I left off</span>
      <textarea data-leftoff="${esc(p.name)}" rows="2" placeholder="Note for future you — what was in your head?" aria-label="Where I left off on ${esc(p.name)}">${esc(p.leftoff)}</textarea>
    </div>
    <div class="ex-foot"><button class="plain ex-link" data-name="${esc(p.name)}">Open full details →</button></div>
  </div>`;
}

function row(p, focusFull) {
  const d = derive(p);
  const flags = [];
  if (d.blockers) flags.push(`<span class="crit">⛔ ${d.blockers} blocked</span>`);
  if (d.g && d.g.decisions.length) flags.push(`<span class="warn">◆ ${plural(d.g.decisions.length, 'decision')}</span>`);
  if (p.local.dirty) flags.push(`<span>${p.local.dirty} uncommitted</span>`);
  if (!flags.length) flags.push('<span>clean</span>');

  const full = focusFull && !p.focus;
  const starTitle = full ? 'Focus is full' : 'Add to focus';
  const open = state.expanded === p.name;

  return `<div class="row-wrap">
    <div class="row cols ${d.section}">
      <button class="plain star-btn${full ? ' full' : ''}" data-star="${esc(p.name)}" aria-label="${starTitle}: ${esc(p.name)}" data-tip="${starTitle}">☆</button>
      <div class="proj">
        <button class="plain name" data-expand="${esc(p.name)}" aria-expanded="${open}" title="Where I left off">${esc(p.name)}<svg class="caret${open ? ' open' : ''}" width="8" height="8" viewBox="0 0 8 8" aria-hidden="true"><path d="M2.5 1.5 5.5 4l-3 2.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
        <span class="flags">${flags.join('')}</span>
      </div>
      ${msBlock(d)}
      <div class="next-cell">${nextCell(p, d)}</div>
      <div class="spark" role="img" aria-label="Commits per week, last 12 weeks">${bars(p.local.weekly, 22, css(d.section === 'motion' ? 'spark' : 'spark-cold'), commitTip(p))}</div>
      <div class="last"><span class="dot" style="background:${css(SECTION_DOT[d.section])}"></span>${ago(p.local.idle)}</div>
    </div>
    ${open ? expandPanel(p, d) : ''}
  </div>`;
}

function table(projects) {
  const q = state.filter.trim().toLowerCase();
  const match = (p) => !q || p.name.toLowerCase().includes(q) || (derive(p).ms.title || '').toLowerCase().includes(q);
  const by = (s) => projects.filter((p) => derive(p).section === s);
  const idle = (a, b) => (a.local.idle ?? 1e9) - (b.local.idle ?? 1e9);
  // Stalled projects closest to done first: they're the cheapest to revive.
  const finished = (a, b) => (b.finished || '').localeCompare(a.finished || '') || idle(a, b);
  const closest = (a, b) => (derive(b).ms.pct ?? -1) - (derive(a).ms.pct ?? -1) || idle(a, b);
  const lists = { motion: by('motion').sort(idle), stalled: by('stalled').sort(closest), done: by('done').sort(finished), parked: by('parked').sort(idle), archived: by('archived').sort(idle) };
  const focusFull = by('focus').length >= state.data.focusLimit;

  const tabs = [
    ['all', 'All', Object.values(lists).reduce((n, l) => n + l.length, 0)],
    ['motion', 'In motion', lists.motion.length],
    ['stalled', 'Stalled', lists.stalled.length],
    ['done', 'Done', lists.done.length],
  ];
  const shown = state.tab === 'all'
    ? ['motion', 'stalled', 'done', 'parked', 'archived'].filter((k) => k === 'motion' || k === 'stalled' || lists[k].length)
    : [state.tab];

  if (state.view === 'board') return projectsBlock(kanban(projects, match));
  return projectsBlock(`
    <div class="tabs" role="tablist">${tabs.map(([k, label, n]) => `
      <button class="plain tab${state.tab === k ? ' on' : ''}" role="tab" aria-selected="${state.tab === k}" data-tab="${k}">${label}<span>${n}</span></button>`).join('')}
    </div>
    <div class="table-scroll">
      <div class="table">
        <div class="thead cols"><span></span><span>Project</span><span>Current milestone</span><span>Next step</span><span>Activity</span><span>Last touched</span></div>
        ${shown.map((k) => {
          const [label, color, desc] = GROUPS[k];
          const open = !state.collapsed[k];
          const rows = lists[k].filter(match);
          return `<div class="group">
            <button class="plain group-head" data-group="${k}" aria-expanded="${open}">
              <span class="dot" style="background:${css(color)}"></span>
              <span class="label">${label}</span><span class="n">${lists[k].length}</span>
              <span class="sep">·</span><span class="desc">${desc}</span>
              <span class="chev">${open ? 'Hide' : 'Show'}</span>
            </button>
            ${open ? (rows.length ? rows.map((p) => row(p, focusFull)).join('') : '<div class="empty-row">No projects match.</div>') : ''}
          </div>`;
        }).join('')}
      </div>
    </div>`);
}

function projectsBlock(body) {
  const views = [['board', 'Board'], ['list', 'List']];
  return `<section class="block" id="projects">
    <div class="block-head">
      <h2>All projects<span>${state.data.projects.length}</span></h2>
      <div class="block-tools">
        ${state.view === 'board' ? '<span class="hint">Drag a card to change its status</span>' : ''}
        <div class="seg" role="group" aria-label="View">${views.map(([k, label]) => `
          <button class="plain${state.view === k ? ' on' : ''}" data-view="${k}" aria-pressed="${state.view === k}">${label}</button>`).join('')}
        </div>
      </div>
    </div>
    ${body}
  </section>`;
}

// ---------- kanban ----------

// In motion and stalled come from git activity, so they share the Active column.
const COLUMNS = [
  ['focus', 'Focus', 'blue', 'what you work on this week'],
  ['active', 'Active', 'green', 'on the list, not in focus'],
  ['parked', 'Parked', 'faint', 'set aside on purpose'],
  ['done', 'Done', 'green', 'finished'],
  ['dropped', 'Killed', 'dim-dot', 'let go on purpose'],
];
const columnOf = (p) => (p.status === 'active' ? (p.focus ? 'focus' : 'active') : p.status);
const focusCount = () => state.data.projects.filter((p) => columnOf(p) === 'focus').length;

function card(p) {
  const d = derive(p);
  const flags = [];
  if (d.section === 'stalled') flags.push('<span class="warn">stalled</span>');
  if (d.blockers) flags.push(`<span class="crit">⛔ ${d.blockers} blocked</span>`);
  if (p.local.dirty) flags.push(`<span>${p.local.dirty} uncommitted</span>`);
  const when = p.status === 'done' && p.finished ? `✓ ${fmtDay(p.finished)}` : ago(p.local.idle);
  const ms = !d.ms.none && d.ms.title && p.status === 'active'
    ? `<div class="card-ms"><span>${esc(d.ms.title)}</span><span class="mono">${d.ms.pct}%</span></div>${meter(d.ms.pct, d.ms.title)}` : '';
  return `<div class="card ${d.section}" draggable="true" tabindex="0" role="button" data-name="${esc(p.name)}" data-card="${esc(p.name)}">
    <div class="card-top">
      <span class="name">${esc(p.name)}</span>
      <span class="when"><span class="dot" style="background:${css(SECTION_DOT[d.section])}"></span>${esc(when)}</span>
    </div>
    ${ms}
    ${p.next && p.status === 'active' ? `<div class="card-next">→ ${esc(p.next)}</div>` : ''}
    ${flags.length ? `<div class="flags">${flags.join('')}</div>` : ''}
  </div>`;
}

function kanban(projects, match) {
  const idle = (a, b) => (a.local.idle ?? 1e9) - (b.local.idle ?? 1e9);
  const order = {
    // In-motion projects above stalled ones.
    active: (a, b) => (derive(a).section === 'stalled') - (derive(b).section === 'stalled') || idle(a, b),
    done: (a, b) => (b.finished || '').localeCompare(a.finished || '') || idle(a, b),
  };
  return `<div class="kanban-scroll"><div class="kanban">${COLUMNS.map(([k, label, color, desc]) => {
    const all = projects.filter((p) => columnOf(p) === k);
    const cards = all.filter(match).sort(order[k] || idle);
    const n = k === 'focus' ? `${all.length}/${state.data.focusLimit}` : all.length;
    return `<div class="col col-${k}" data-col="${k}">
      <div class="col-head" title="${esc(desc)}"><span class="dot" style="background:${css(color)}"></span><span class="label">${label}</span><span class="n">${n}</span></div>
      <div class="col-cards">${cards.length ? cards.map(card).join('') : `<div class="col-empty">${all.length ? 'No projects match.' : 'Drop a project here'}</div>`}</div>
    </div>`;
  }).join('')}</div></div>`;
}

// What dropping a card in each column asks the server for.
const MOVES = {
  focus: { focus: true },
  active: { status: 'active', focus: false },
  parked: { status: 'parked' },
  done: { status: 'done' },
  dropped: { status: 'dropped' },
};

async function moveTo(name, col) {
  const p = project(name);
  if (!p || columnOf(p) === col) return;
  if (col === 'focus' && focusCount() >= state.data.focusLimit) {
    return toast(`Focus is full (${state.data.focusLimit}). Move one out first.`, true);
  }
  const msg = col === 'focus' ? `★ ${name} is in focus`
    : col === 'active' && p.status === 'active' ? `${name} left focus`
    : STATUS_MSG[MOVES[col].status];
  // Move the card right away: the server rescans every repo before answering.
  Object.assign(p, col === 'focus' ? { status: 'active', focus: true } : { status: MOVES[col].status, focus: false });
  p.finished = col === 'done' ? state.data.today : null;
  render();
  if (!(await update(name, MOVES[col], msg))) load();
}

function render() {
  const all = state.data.projects;
  const fetched = Math.min(...all.map((p) => p.fetchedAt || Infinity));
  const mins = isFinite(fetched) ? Math.round((Date.now() / 1000 - fetched) / 60) : null;
  $('#sub').textContent = `${all.length} tracked` + (mins != null ? ` · GitHub synced ${mins < 1 ? 'just now' : `${mins} min ago`}` : '');

  $('#app').innerHTML = tiles(all) + focusBlock(all) + ideasBlock(all) + table(all);

  if (state.refocusIdea) {
    state.refocusIdea = false;
    $('[data-idea-form] [name="title"]').focus();
  }
  if (state.startingIdea) $('[data-idea-path]')?.focus();
  if (state.editing) {
    const input = $(`[data-edit="${CSS.escape(state.editing)}"]`);
    if (input) {
      input.focus();
      input.setSelectionRange(input.value.length, input.value.length);
    }
  }
  if (state.open) renderDetail();
}

// ---------- detail ----------

function issueRow(i, roadmap) {
  if (roadmap) {
    return `<li><button class="plain task-box" data-task-line="${i.line}" data-task-text="${esc(i.title)}" aria-label="Mark done: ${esc(i.title)}" data-tip="Check off in the roadmap file">☐</button><span class="t">${esc(i.title)}</span></li>`;
  }
  const flags = [];
  if (i.blocked) flags.push('<span class="tag" style="color:var(--red)">⛔ blocked</span>');
  if (i.decision) flags.push('<span class="tag" style="color:var(--amber)">◆ decision</span>');
  if (i.doing) flags.push('<span class="tag" style="color:var(--blue)">▶ in progress</span>');
  const rest = i.labels.filter((l) => !/block|decision|question|progress|doing|wip/i.test(l)).slice(0, 3);
  return `<li><span class="no">#${i.number}</span><a class="t" href="${esc(i.url)}" target="_blank" rel="noopener">${esc(i.title)}</a>
    <span class="tags">${flags.join('')}${rest.map((l) => `<span class="tag">${esc(l)}</span>`).join('')}</span></li>`;
}

const ROADMAP_HINT = 'add a <code>ROADMAP.md</code> with <code>## Milestone</code> headings and <code>- [ ]</code> tasks, or point pm at an existing checklist with <code>pm roadmap &lt;name&gt; &lt;file&gt;</code>';

function renderDetail() {
  const p = state.data.projects.find((x) => x.name === state.open);
  const dlg = $('#detail');
  if (!p) return dlg.close();
  const d = derive(p);
  const { g, cur, hasRoadmap, roadmap } = d;
  const refocus = document.activeElement && document.activeElement.dataset && document.activeElement.dataset.field;

  const actions = p.status === 'active'
    ? `<button class="btn${p.focus ? '' : ' primary'}" data-act="focus">${p.focus ? '★ Unfocus' : '☆ Focus'}</button>
       <button class="btn" data-act="status" data-v="parked">Park</button>
       <button class="btn" data-act="status" data-v="done">Mark done</button>
       <button class="btn danger" data-act="status" data-v="dropped">Kill</button>`
    : `<button class="btn primary" data-act="status" data-v="active">${p.status === 'done' ? '↺ Reopen' : '↺ Restore'}</button>
       <span class="d-meta">This project is ${p.status === 'dropped' ? 'killed' : esc(p.status)}.</span>`;

  let progressHtml;
  if (!g) {
    progressHtml = `<div class="hint-box">${p.tracker && p.tracker.error ? "Couldn't load GitHub issues for this repo." : `No progress tracking yet. To get a progress bar, ${ROADMAP_HINT}.`}</div>`;
  } else if (!g.total) {
    progressHtml = `<div class="hint-box">No issues yet. Break the project into issues grouped into a milestone such as <b>MVP</b> (<a href="${esc(g.url)}/milestones/new" target="_blank" rel="noopener">create a milestone</a>), or ${ROADMAP_HINT}.</div>`;
  } else if (!hasRoadmap) {
    progressHtml = `${msBlock(d)}<div class="hint-box" style="margin-top:12px">Tip: group these issues into milestones (e.g. <b>MVP</b>, <b>Playable demo</b>, <b>Release</b>) to get a roadmap and a finish line that's actually reachable. <a href="${esc(g.url)}/milestones/new" target="_blank" rel="noopener">Create a milestone →</a></div>`;
  } else {
    progressHtml = `<ol class="ms-list">${g.milestones.map((m) => {
      const pct = m.total ? Math.round((100 * m.closed) / m.total) : 0;
      const cls = m.done ? 'done' : m.number === g.current ? 'current' : '';
      const mark = m.done ? '✓' : m.number === g.current ? '▶' : '·';
      const extra = `${m.number === g.current ? '<small>current</small>' : ''}${!m.total ? '<small>no issues</small>' : ''}`;
      const title = m.url ? `<a class="t" href="${esc(m.url)}" target="_blank" rel="noopener">${esc(m.title)}${extra}</a>` : `<span class="t">${esc(m.title)}${extra}</span>`;
      return `<li class="${cls}"><span class="mark" aria-hidden="true">${mark}</span>${title}${meter(pct, m.title)}<span class="num">${m.closed}/${m.total}</span></li>`;
    }).join('')}</ol>`;
  }

  const leftTitle = cur ? `What's left in ${esc(cur.title)}` : hasRoadmap ? 'Open issues outside milestones' : 'Open issues';
  const leftList = g ? (cur || !hasRoadmap ? g.left : []) : [];
  const leftMore = g ? g.leftCount - leftList.length : 0;
  const moreLink = roadmap ? `<span class="more">+${leftMore} more in ${esc(g.file)}</span>`
    : `<a class="more" href="${esc(cur ? cur.url : g.url + '/issues')}" target="_blank" rel="noopener">+${leftMore} more on GitHub →</a>`;
  const leftHtml = g && g.total && (cur || !hasRoadmap) ? `<section><h3>${leftTitle}<span class="count">${g.leftCount}</span></h3>
      ${leftList.length ? `<ul class="issues">${leftList.map((i) => issueRow(i, roadmap)).join('')}</ul>` : '<div class="hint-box">Nothing left here.</div>'}
      ${leftMore > 0 ? moreLink : ''}
    </section>` : '';

  const blockHtml = g ? `
    ${g.blockers.length ? `<section><h3>Blocked<span class="count">${g.blockers.length}</span></h3><ul class="issues">${g.blockers.map((i) => issueRow(i)).join('')}</ul></section>` : ''}
    ${g.decisions.length ? `<section><h3>Decisions waiting on you<span class="count">${g.decisions.length}</span></h3><ul class="issues">${g.decisions.map((i) => issueRow(i)).join('')}</ul></section>` : ''}` : '';

  const commits = p.local.recent.length
    ? `<ul class="commits">${p.local.recent.map((c) => `<li><time>${esc(fmtDay(c.date))}</time><span>${esc(c.subject)}</span></li>`).join('')}</ul>` : '';
  const source = !g ? '' : roadmap ? `Progress from <span class="mono">${esc(g.file)}</span>${g.edited ? `, edited ${esc(fmtDay(g.edited))}` : ''}` : 'Progress from GitHub issues';

  dlg.innerHTML = `
    <div class="d-head">
      <div class="d-title">
        <h2 id="detail-title" tabindex="-1" autofocus>${esc(p.name)}</h2>
        <span class="health"><span class="dot" style="background:${css(SECTION_DOT[d.section])}"></span>${p.local.health === 'unknown' ? 'No activity' : p.local.health[0].toUpperCase() + p.local.health.slice(1)} · ${ago(p.local.idle)}</span>
        <button class="close-x" data-act="close" aria-label="Close">×</button>
      </div>
      <div class="d-meta">
        <span>${esc(p.displayPath)}</span>
        ${p.repoUrl ? `<a href="${esc(p.repoUrl)}" target="_blank" rel="noopener">${esc(p.local.slug)} ↗</a>` : ''}
        <span>${plural(p.local.commits, 'commit')}</span>
        ${p.local.dirty ? `<span>${p.local.dirty} uncommitted</span>` : ''}
      </div>
      <div class="d-actions">${actions}</div>
    </div>
    <div class="d-body">
      <section class="fields">
        <label class="field"><span>Next step</span><input data-field="next" value="${esc(p.next)}" placeholder="The very next concrete action, small enough to start in 5 minutes"></label>
        <label class="field"><span>Where I left off</span><input data-field="leftoff" value="${esc(p.leftoff)}" placeholder="Note for future you — what was in your head?"></label>
        <label class="field"><span>Why it matters</span><input data-field="why" value="${esc(p.why)}" placeholder="What made you start this? Future-you needs reminding"></label>
        <label class="field"><span>Blocker</span><input data-field="blocker" value="${esc(p.blocker)}" placeholder="Anything outside GitHub stopping you (waiting on art, a decision…)"></label>
      </section>
      <section><h3>Roadmap${g && g.total ? `<span class="count">${g.done}/${g.total} ${d.unit}s · ${g.progress}%</span>` : ''}</h3>
        ${source ? `<p class="source">${source}</p>` : ''}${progressHtml}</section>
      ${leftHtml}
      ${blockHtml}
      <section><h3>Activity<span class="count">commits per week, last 12 weeks</span></h3>
        <div class="d-spark" role="img" aria-label="Commits per week, last 12 weeks">${bars(p.local.weekly, 56, css('spark'), commitTip(p))}</div>
        ${commits}
      </section>
      <section><h3>Journal</h3>
        ${p.log.length ? `<ul class="journal">${p.log.slice().reverse().map((e) => `<li><time>${esc(fmtDay(e.date))}</time><span>${esc(e.note)}</span></li>`).join('')}</ul>` : ''}
        <label class="field"><input data-note placeholder="Add a note and press Enter" aria-label="Add a journal note"></label>
      </section>
    </div>`;
  if (!dlg.open) dlg.showModal();
  if (refocus) $(`[data-field="${refocus}"]`, dlg)?.focus();
}

function openDetail(name) {
  state.open = name;
  renderDetail();
  $('#detail').scrollTop = 0;
}

// ---------- tooltip & toast ----------

const tip = $('#tip');
document.addEventListener('pointerover', (e) => {
  const t = e.target.closest('[data-tip]');
  if (!t) return (tip.hidden = true);
  tip.textContent = t.getAttribute('data-tip');
  tip.hidden = false;
  const r = t.getBoundingClientRect();
  const tw = tip.offsetWidth, th = tip.offsetHeight;
  tip.style.left = Math.max(8, Math.min(innerWidth - tw - 8, r.left + r.width / 2 - tw / 2)) + 'px';
  tip.style.top = (r.top - th - 8 < 8 ? r.bottom + 8 : r.top - th - 8) + 'px';
});
document.addEventListener('scroll', () => (tip.hidden = true), true);

let toastTimer;
function toast(msg, err = false) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = err ? 'err' : '';
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), err ? 5000 : 2200);
}

// ---------- events ----------

const project = (name) => state.data.projects.find((x) => x.name === name);
const STATUS_MSG = {
  parked: 'Parked. It will wait, guilt-free.',
  done: 'Done. Nice work! 🎉',
  dropped: 'Killed. Letting go is a decision, not a failure.',
  active: 'Back on the board.',
};

function toggleFocus(p) {
  return update(p.name, { focus: !p.focus }, p.focus ? `${p.name} left focus` : `★ ${p.name} is in focus`);
}

async function saveNext(input, commit) {
  const name = input.dataset.edit;
  state.editing = null;
  const p = project(name);
  if (commit && p && input.value.trim() !== p.next) await update(name, { next: input.value }, 'Next step saved');
  else render();
}

async function acceptAll() {
  const names = [...document.querySelectorAll('[data-focus-it]')].map((b) => b.dataset.focusIt);
  state.suggest = false;
  for (const name of names) {
    if (!(await post('/api/projects/' + encodeURIComponent(name), { focus: true }))) break;
  }
  await load();
  toast(`★ ${names.join(', ')} ${names.length === 1 ? 'is' : 'are'} in focus`);
}

async function startIdea(id, path) {
  const res = await postJson(`/api/ideas/${id}`, { action: 'start', path });
  if (!res) return;
  state.startingIdea = null;
  await load();
  toast(`★ ${res.project} ${res.created ? 'created' : 'linked'} and in focus. Go!`);
}

async function dropIdea(id) {
  if (!(await post(`/api/ideas/${id}`, { action: 'drop' }))) return;
  await load();
  toast("Let go. That's a project you'll never have to abandon.");
}

$('#app').addEventListener('submit', async (e) => {
  const form = e.target.closest('[data-idea-form]');
  if (!form) return;
  e.preventDefault();
  const title = form.title.value.trim();
  if (!title) return;
  if (!(await post('/api/ideas', { title, pitch: form.pitch.value }))) return;
  state.refocusIdea = true;
  await load();
  const ready = new Date();
  ready.setDate(ready.getDate() + state.data.ideas.cooldown);
  toast(`Parked. If you still want it on ${ready.toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' })}, it's yours.`);
});

$('#app').addEventListener('click', (e) => {
  const ideaBtn = e.target.closest('[data-idea-start],[data-idea-go],[data-idea-cancel],[data-idea-drop]');
  if (ideaBtn) {
    const ds = ideaBtn.dataset;
    if (ds.ideaStart) {
      if ('full' in ds) return toast(`Focus is full (${state.data.focusLimit}). Finish, park or unstar a project first.`, true);
      state.startingIdea = Number(ds.ideaStart);
      state.droppingIdea = null;
    } else if (ds.ideaGo) {
      return startIdea(ds.ideaGo, $('[data-idea-path]').value);
    } else if ('ideaCancel' in ds) {
      state.startingIdea = null;
    } else if (ds.ideaDrop) {
      if ('confirmed' in ds) {
        state.droppingIdea = null;
        return dropIdea(ds.ideaDrop);
      }
      state.droppingIdea = Number(ds.ideaDrop);
    }
    return render();
  }
  if (e.target.closest('a')) return;
  const el = e.target.closest('[data-act],[data-star],[data-focus-it],[data-skip],[data-revive],[data-status],[data-editbtn],[data-expand],[data-tab],[data-view],[data-group],[data-jump],[data-name]');
  if (!el) return;
  const ds = el.dataset;
  if (ds.act === 'suggest') {
    state.suggest = true;
    state.skipped = [];
    return render();
  }
  if (ds.act === 'dismiss') {
    state.suggest = false;
    return render();
  }
  if (ds.act === 'accept-all') return acceptAll();
  if (ds.star) {
    if (el.classList.contains('full')) return toast(`Focus is full (${state.data.focusLimit}). Unstar one first.`, true);
    return toggleFocus(project(ds.star));
  }
  if (ds.focusIt) return update(ds.focusIt, { focus: true }, `★ ${ds.focusIt} is in focus`);
  if (ds.skip) {
    state.skipped.push(ds.skip);
    return render();
  }
  if (ds.revive) return update(ds.revive, { focus: true }, `${ds.revive} is back in focus. Pick one small step.`);
  if (ds.status) return update(ds.who, { status: ds.status }, STATUS_MSG[ds.status]);
  if (ds.editbtn) {
    state.editing = ds.editbtn;
    return render();
  }
  if (ds.expand) {
    state.expanded = state.expanded === ds.expand ? null : ds.expand;
    return render();
  }
  if (ds.tab) {
    state.tab = ds.tab;
    return render();
  }
  if (ds.view) {
    state.view = ds.view;
    try { localStorage.setItem('pm-view', ds.view); } catch {}
    return render();
  }
  if (ds.group) {
    state.collapsed[ds.group] = !state.collapsed[ds.group];
    return render();
  }
  if (ds.jump) {
    if (ds.jump === 'focus') return $('#focus').scrollIntoView({ behavior: 'smooth' });
    state.tab = ds.jump;
    state.view = 'list';
    render();
    return $('#projects').scrollIntoView({ behavior: 'smooth' });
  }
  if (ds.name) openDetail(ds.name);
});

$('#app').addEventListener('keydown', (e) => {
  const input = e.target.closest('[data-edit]');
  if (input) {
    if (e.key === 'Enter') saveNext(input, true);
    if (e.key === 'Escape') saveNext(input, false);
    return;
  }
  if (e.key === 'Enter' && e.target.matches('.slot[data-name], .card[data-name]')) openDetail(e.target.dataset.name);
});

let dragged = null;
const clearDrag = () => document.querySelectorAll('.dragging, .over, .refuse, .drag-on')
  .forEach((el) => el.classList.remove('dragging', 'over', 'refuse', 'drag-on'));

$('#app').addEventListener('dragstart', (e) => {
  const c = e.target.closest('[data-card]');
  if (!c) return;
  dragged = project(c.dataset.card);
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/plain', dragged.name);
  c.classList.add('dragging');
  $('.kanban').classList.add('drag-on');
  if (!dragged.focus && focusCount() >= state.data.focusLimit) $('.col-focus').classList.add('refuse');
});
$('#app').addEventListener('dragend', () => {
  dragged = null;
  clearDrag();
});
$('#app').addEventListener('dragover', (e) => {
  const col = dragged && e.target.closest('[data-col]');
  if (!col) return;
  e.preventDefault();
  const refused = col.classList.contains('refuse');
  e.dataTransfer.dropEffect = refused ? 'none' : 'move';
  document.querySelectorAll('.col.over').forEach((el) => el !== col && el.classList.remove('over'));
  if (!refused) col.classList.add('over');
});
$('#app').addEventListener('dragleave', (e) => {
  const col = e.target.closest('[data-col]');
  if (col && !col.contains(e.relatedTarget)) col.classList.remove('over');
});
$('#app').addEventListener('drop', (e) => {
  const col = dragged && e.target.closest('[data-col]');
  if (!col) return;
  e.preventDefault();
  const name = dragged.name;
  dragged = null;
  clearDrag();
  moveTo(name, col.dataset.col);
});

$('#app').addEventListener('focusout', (e) => {
  const input = e.target.closest('[data-edit]');
  if (input && state.editing === input.dataset.edit) saveNext(input, true);
});

$('#app').addEventListener('change', (e) => {
  const name = e.target.dataset.leftoff;
  if (name !== undefined && e.target.value.trim() !== (project(name).leftoff || '')) {
    update(name, { leftoff: e.target.value }, 'Saved for future you');
  }
});

const dlg = $('#detail');
dlg.addEventListener('click', async (e) => {
  if (e.target === dlg) return dlg.close(); // backdrop
  const box = e.target.closest('[data-task-line]');
  if (box) {
    const ok = await post(`/api/projects/${encodeURIComponent(state.open)}/task`, { line: Number(box.dataset.taskLine), text: box.dataset.taskText, done: true });
    if (ok) {
      await load();
      toast(`Checked off: ${box.dataset.taskText}`);
    }
    return;
  }
  const btn = e.target.closest('[data-act]');
  if (!btn) return;
  const p = project(state.open);
  const act = btn.dataset.act;
  if (act === 'close') dlg.close();
  if (act === 'focus') toggleFocus(p);
  if (act === 'status') update(p.name, { status: btn.dataset.v }, STATUS_MSG[btn.dataset.v]);
});
dlg.addEventListener('change', (e) => {
  const f = e.target.dataset.field;
  if (f) update(state.open, { [f]: e.target.value }, 'Saved');
});
dlg.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter') return;
  if (e.target.dataset.field) e.target.blur();
  if (e.target.hasAttribute('data-note') && e.target.value.trim()) update(state.open, { note: e.target.value }, 'Noted');
});
dlg.addEventListener('close', () => (state.open = null));

$('#refresh').addEventListener('click', () => load(true));
$('#filter').addEventListener('input', (e) => {
  state.filter = e.target.value;
  render();
});
document.addEventListener('keydown', (e) => {
  if (e.key === '/' && !e.target.matches('input, textarea')) {
    e.preventDefault();
    $('#filter').focus();
  }
});
document.addEventListener('visibilitychange', () => {
  const typing = document.activeElement && document.activeElement.matches('input, textarea');
  if (!document.hidden && !state.open && !state.editing && !typing) load();
});

load();
