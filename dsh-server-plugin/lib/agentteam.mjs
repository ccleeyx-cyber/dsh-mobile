/**
 * Agent Team projection read model for the phone.
 *
 * ## What this is for
 *
 * The Web client's team panel reads exactly one thing:
 * `projectionsBySession[leadSessionId].values.agentTeam` (see
 * `dsh-experimental-client-ui-agent-team/lib/client.js:239`), which is the
 * **wire view** of the `agentTeam` projection defined in
 * `dsh-experimental-agent-team/lib/types/projection.js:319`.
 *
 * The phone has no projection subscription — it polls — so this module turns
 * that same wire view into the rows the App renders, and the gateway serves it
 * over `/api/mobile/sessions/team`.
 *
 * ## The two sources, and why both
 *
 * 1. `session/projections` RPC — authoritative for a **live** session, and the
 *    only source that reflects a turn in progress. It returns
 *    `{ values: { agentTeam: {...} } }`.
 * 2. The projection-cache record (`rows.agentTeam.val`) — a **checkpoint**. This
 *    is the historical state (`members[].phase`, the task board) of a session
 *    that is no longer running, which is the overwhelmingly common case when the
 *    phone opens yesterday's work.
 *
 * They are the same projection at different watermarks, so a disagreement is
 * never a contradiction: the RPC wins whenever it answers, because it is newer.
 *
 * ## Why normalize here instead of forwarding the raw value
 *
 * The wire schema is `.strict()` with 9 member fields and 11 task fields. The
 * phone only needs a handful, and forwarding the raw projection means every
 * engine-side field addition becomes a client-side parse risk. This module is
 * also where "engine can't do teams at all" becomes a distinguishable answer
 * (`null` → 501) rather than a silently empty panel that reads as "no team".
 */

/** One teammate, plus the synthetic Lead row the Web panel also shows. */
const MEMBER_PHASES = new Set(['provisioning', 'active', 'failed']);
const MEMBER_ROLES = new Set(['lead', 'teammate']);

/** Task board statuses; `deleted` is filtered out by the engine's own wire view. */
const TASK_STATUSES = new Set(['pending', 'in_progress', 'completed', 'deleted']);

/** Bounds so one malformed projection cannot blow up the phone's response. */
const MAX_MEMBERS = 64;
const MAX_TASKS = 200;
const MAX_TEXT = 2000;

/**
 * Coerce one member row, or null when it is unusable.
 *
 * @param {unknown} raw
 * @returns {{ id: string, name: string, role: string, phase: string, error: string } | null}
 */
function normalizeMember(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = typeof raw.id === 'string' ? raw.id.trim() : '';
  if (!id) return null;
  return {
    id,
    name: typeof raw.name === 'string' && raw.name.trim() ? raw.name.trim() : id,
    role: MEMBER_ROLES.has(raw.role) ? raw.role : 'teammate',
    phase: MEMBER_PHASES.has(raw.phase) ? raw.phase : 'provisioning',
    error: typeof raw.error === 'string' ? raw.error.slice(0, 400) : ''
  };
}

/**
 * Coerce one task row, or null when it is unusable.
 *
 * @param {unknown} raw
 * @returns {object | null}
 */
function normalizeTask(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const id = typeof raw.id === 'string' ? raw.id.trim() : '';
  if (!id) return null;
  const revision = Number(raw.revision);
  const owner = typeof raw.ownerName === 'string' ? raw.ownerName.trim() : '';
  const list = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === 'string') : []);
  return {
    id,
    revision: Number.isSafeInteger(revision) && revision > 0 ? revision : 1,
    subject: typeof raw.subject === 'string' ? raw.subject.slice(0, 200) : '',
    description: typeof raw.description === 'string' ? raw.description.slice(0, MAX_TEXT) : '',
    status: TASK_STATUSES.has(raw.status) ? raw.status : 'pending',
    blockedBy: list(raw.blockedBy).slice(0, MAX_TASKS),
    ownerName: owner || '',
    ready: raw.ready === true,
    writeScopes: list(raw.writeScopes).slice(0, 32)
  };
}

/**
 * Normalize the `agentTeam` wire view (or cached checkpoint) into phone rows.
 *
 * ⚠️ Returns `null` — not an empty team — when the input cannot be a team at
 * all. The gateway turns that into a 501 so the App can say "this engine has no
 * team support" instead of rendering an empty panel that the user reads as
 * "my team is gone". An engine that genuinely has a team with zero teammates
 * still answers `{ members: [lead], tasks: [] }`, which is a **truthful** empty
 * team and is returned normally.
 *
 * @param {unknown} value - `values.agentTeam`, or `rows.agentTeam.val`.
 * @param {object} [opts]
 * @param {boolean} [opts.leadPresent] - the value came from a projection that
 *   synthesizes the Lead row (the RPC wire view and the cache both do). Kept as
 *   an explicit switch so a future source without it is not silently trusted.
 * @returns {{ members: object[], tasks: object[], failure: string } | null}
 */
export function normalizeAgentTeam(value, { leadPresent = true } = {}) {
  if (!value || typeof value !== 'object') return null;
  if (!Array.isArray(value.members)) return null;

  const members = value.members.map(normalizeMember).filter(Boolean).slice(0, MAX_MEMBERS);
  // The Lead is the session itself. Its row is synthesized by the projection, so
  // a cache or RPC value without one is still a team — just re-attach the Lead.
  const hasLead = members.some((m) => m.role === 'lead');
  if (leadPresent && !hasLead) {
    members.unshift({ id: '', name: 'lead', role: 'lead', phase: 'active', error: '' });
  }

  const tasks = Array.isArray(value.tasks)
    ? value.tasks.map(normalizeTask).filter(Boolean).filter((t) => t.status !== 'deleted').slice(0, MAX_TASKS)
    : [];

  return {
    members,
    tasks,
    failure: typeof value.failure === 'string' ? value.failure.slice(0, 400) : ''
  };
}

/**
 * Read `agentTeam` out of a projection-cache rows object.
 *
 * @param {unknown} rows - `record.rows` of a projection-cache file.
 * @returns {object | null} the same shape {@link normalizeAgentTeam} returns.
 */
export function agentTeamFromProjectionRows(rows) {
  if (!rows || typeof rows !== 'object') return null;
  // Cached checkpoints store the projection **state** (`{ id, members, tasks,
  // messages, delivered, nextTaskNumber }`), not the wire view — `members` there
  // carry `provider`/`context`/`description` and no `role`. Mapping them onto the
  // wire view is exactly what the engine's `buildTeamProjection` does.
  const raw = rows?.agentTeam?.val;
  if (!raw || typeof raw !== 'object') return null;
  return normalizeAgentTeam({
    members: (Array.isArray(raw.members) ? raw.members : []).map((m) => ({
      id: m?.id,
      name: m?.name,
      role: 'teammate',
      phase: m?.phase,
      error: m?.error
    })),
    tasks: Array.isArray(raw.tasks) ? raw.tasks : [],
    failure: raw.failure
  });
}

/**
 * Roll team rows up into the counters the phone's summary row shows.
 *
 * @param {{ members: object[], tasks: object[] }} team
 * @returns {{ total: number, active: number, provisioning: number, failed: number,
 *   tasksTotal: number, tasksInProgress: number, tasksCompleted: number }}
 */
export function summarizeAgentTeam(team) {
  const members = Array.isArray(team?.members) ? team.members : [];
  const tasks = Array.isArray(team?.tasks) ? team.tasks : [];
  let active = 0, provisioning = 0, failed = 0;
  for (const m of members) {
    if (m.role === 'lead') continue;
    if (m.phase === 'active') active++;
    else if (m.phase === 'failed') failed++;
    else provisioning++;
  }
  return {
    total: members.filter((m) => m.role !== 'lead').length,
    active,
    provisioning,
    failed,
    tasksTotal: tasks.length,
    tasksInProgress: tasks.filter((t) => t.status === 'in_progress').length,
    tasksCompleted: tasks.filter((t) => t.status === 'completed').length
  };
}
