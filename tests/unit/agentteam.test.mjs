/**
 * Unit tests for lib/agentteam.mjs
 *
 * The wire contract is the engine's own `teamProjectionSchema`
 * (`dsh-experimental-agent-team/lib/types/projection.js:268`); the cached shape is
 * the projection **state** it folds from. Both must reach the same phone rows.
 *
 * Runs without a live bridge — `node tests/unit/agentteam.test.mjs`.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizeAgentTeam,
  agentTeamFromProjectionRows,
  summarizeAgentTeam
} from '../../dsh-server-plugin/lib/agentteam.mjs';

/** A wire view shaped exactly like the engine's, taken from a real team session. */
const wireView = () => ({
  members: [
    { id: 'session-lead', name: 'lead', role: 'lead', phase: 'active' },
    { id: '718d0852', name: 'report-analyst', role: 'teammate', phase: 'active' },
    { id: '54d8b3b2', name: 'teaching-analyst', role: 'teammate', phase: 'provisioning' },
    { id: 'c2dbac66', name: 'finance-analyst', role: 'teammate', phase: 'failed', error: 'spawn timed out' }
  ],
  tasks: [
    {
      id: 'task-1',
      revision: 3,
      subject: '审计报表端点',
      description: '逐个看 81 个端点',
      status: 'in_progress',
      blockedBy: [],
      writeScopes: ['server/'],
      ownerName: 'report-analyst',
      ready: true,
      writeScopeWarnings: []
    },
    {
      id: 'task-2',
      revision: 1,
      subject: '审计财务端点',
      description: '',
      status: 'pending',
      blockedBy: ['task-1'],
      writeScopes: [],
      ready: false,
      writeScopeWarnings: []
    },
    {
      id: 'task-3',
      revision: 1,
      subject: '已删任务',
      description: '',
      status: 'deleted',
      blockedBy: [],
      writeScopes: [],
      ready: true,
      writeScopeWarnings: []
    }
  ]
});

describe('normalizeAgentTeam', () => {
  it('keeps every member and re-attaches the Lead when the source omits it', () => {
    const team = normalizeAgentTeam({ members: [{ id: 'a', name: 'x', phase: 'active' }], tasks: [] });
    assert.equal(team.members.length, 2);
    assert.equal(team.members[0].role, 'lead');
    assert.equal(team.members[1].role, 'teammate');
  });

  it('does not duplicate a Lead the source already synthesized', () => {
    const team = normalizeAgentTeam(wireView());
    assert.equal(team.members.filter((m) => m.role === 'lead').length, 1);
  });

  it('filters deleted tasks and keeps the rest', () => {
    const team = normalizeAgentTeam(wireView());
    assert.deepEqual(team.tasks.map((t) => t.id), ['task-1', 'task-2']);
  });

  it('coerces an unknown phase to provisioning rather than inventing active', () => {
    // A teammate that claims "active" when the engine said nothing new would be
    // a lie the phone renders as "正在工作".
    const team = normalizeAgentTeam({ members: [{ id: 'a', name: 'x', phase: 'wat' }], tasks: [] });
    assert.equal(team.members.find((m) => m.id === 'a').phase, 'provisioning');
  });

  it('defaults a nameless member to its id instead of an empty row', () => {
    const team = normalizeAgentTeam({ members: [{ id: 'abc', phase: 'active' }], tasks: [] });
    assert.equal(team.members.find((m) => m.id === 'abc').name, 'abc');
  });

  it('repairs an invalid revision instead of dropping the task', () => {
    const team = normalizeAgentTeam({
      members: [],
      tasks: [{ id: 't', revision: 0, subject: 's', status: 'pending', blockedBy: [], ready: true }]
    });
    assert.equal(team.tasks[0].revision, 1);
  });

  it('returns null — not an empty team — when the input is not a team at all', () => {
    // The gateway turns this into `supported:false`; an empty team here would
    // read on the phone as "your teammates are all gone".
    assert.equal(normalizeAgentTeam(null), null);
    assert.equal(normalizeAgentTeam({}), null);
    assert.equal(normalizeAgentTeam({ members: 'nope' }), null);
  });

  it('treats a team with only the Lead as a real, truthfully empty team', () => {
    const team = normalizeAgentTeam({ members: [{ id: 's', name: 'lead', role: 'lead', phase: 'active' }], tasks: [] });
    assert.notEqual(team, null);
    assert.equal(team.members.length, 1);
  });

  it('surfaces a projection failure verbatim', () => {
    const team = normalizeAgentTeam({ members: [], tasks: [], failure: 'team projection diverged' });
    assert.equal(team.failure, 'team projection diverged');
  });

  it('drops malformed rows instead of rendering undefined', () => {
    const team = normalizeAgentTeam({ members: [null, {}, { id: 'ok', name: 'n' }], tasks: [null, 7] });
    // Only the one usable member survives (plus the synthesized Lead row, whose
    // id is empty because the source had no session identity to carry).
    assert.deepEqual(team.members.map((m) => m.name).filter((n) => n && n !== 'lead'), ['n']);
    assert.equal(team.tasks.length, 0);
  });
});

describe('agentTeamFromProjectionRows', () => {
  it('maps a cached checkpoint state onto the wire view', () => {
    // Shape taken from the real archived checkpoint of a 8-member team session.
    const rows = {
      agentTeam: {
        val: {
          id: 'session-26eaa97b',
          members: [
            { id: '718d0852', name: 'report-analyst', provider: 'spawn', context: 'fresh', phase: 'active', description: '分析报表类端点 bug 与慢查询' },
            { id: '54d8b3b2', name: 'teaching-analyst', provider: 'spawn', context: 'fresh', phase: 'active', description: '分析成绩与教学类端点' }
          ],
          tasks: [],
          messages: [],
          delivered: [],
          nextTaskNumber: 1
        }
      }
    };
    const team = agentTeamFromProjectionRows(rows);
    assert.equal(team.members.length, 3); // lead + 2 teammates
    assert.equal(team.members.filter((m) => m.role !== 'lead').length, 2);
    assert.deepEqual(team.members[1].name, 'report-analyst');
    assert.equal(team.members[1].role, 'teammate');
  });

  it('returns null when the projection row is absent or empty', () => {
    assert.equal(agentTeamFromProjectionRows({}), null);
    assert.equal(agentTeamFromProjectionRows({ agentTeam: { val: null } }), null);
    assert.equal(agentTeamFromProjectionRows(null), null);
  });
});

describe('summarizeAgentTeam', () => {
  it('counts phases without counting the Lead as a teammate', () => {
    const s = summarizeAgentTeam(normalizeAgentTeam(wireView()));
    assert.equal(s.total, 3);
    assert.equal(s.active, 1);
    assert.equal(s.provisioning, 1);
    assert.equal(s.failed, 1);
    assert.equal(s.tasksTotal, 2);
    assert.equal(s.tasksInProgress, 1);
    assert.equal(s.tasksCompleted, 0);
  });

  it('does not throw on a missing team', () => {
    const s = summarizeAgentTeam(null);
    assert.equal(s.total, 0);
    assert.equal(s.tasksTotal, 0);
  });
});
