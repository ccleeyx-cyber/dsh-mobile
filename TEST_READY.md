# TEST_READY: DSH Mobile & Server Bridge E2E Test Suite

## 1. Test Suite Runner Command

```bash
# Execute complete E2E test suite
node --test --test-concurrency=1 "tests/e2e/**/*.test.js"

# Alternatively using npm
npm test

# Execute tier-specific test suites
npm run test:tier1   # Feature Coverage (T1)
npm run test:tier2   # Boundary & Corner Cases (T2)
npm run test:tier3   # Cross-Feature Combinations (T3)
npm run test:tier4   # Real-World Mobile Workloads (T4)
```

---

## 2. Execution Summary

- **Test Framework**: Native Node.js test runner (`node:test`, `node:assert/strict`)
- **Runtime**: Node.js v24.14.0 (Windows x64)
- **Total Test Suites**: 23
- **Total Test Cases**: 93
- **Passing**: 89
- **Failing (Exposing Live Server Defects)**: 4
- **Execution Time**: ~16.5 seconds

---

## 3. Feature Coverage Checklist

| Feature ID | Feature Name | Tier | Test File | Test Count | Pass / Fail | Description |
|---|---|---|---|---|---|---|
| **F1.1** | Virtual Keyboard Avoidance | Tier 1, 4 | `mobile-full-lifecycle.test.js` | 1 | PASS | Insets & layout sanity |
| **F1.2** | Delta-Driven Auto-Scroll | Tier 3, 4 | `mobile-full-lifecycle.test.js` | 1 | PASS | Streaming subscription contract |
| **F1.3** | Ergonomic Card Folding | Tier 1, 4 | `mobile-full-lifecycle.test.js` | 1 | PASS | Message & thinking card contracts |
| **F1.4** | Haptic Touch Cues | Tier 1, 4 | `mobile-approval-flow.test.js` | 1 | PASS | Action response triggers |
| **F1.5** | Immediate Cancel Turn UI Transition | Tier 1, 3 | `prompt-and-cancel.test.js`, `multi-client-broadcast.test.js` | 8 | PASS | Immediate `session_status: isRunning=false` |
| **F2.1** | Mobile-First Approval Cards | Tier 1, 4 | `approvals.test.js`, `mobile-approval-flow.test.js` | 6 | PASS | One-tap allow & reject with reason |
| **F2.2** | Cross-View Pending Badges | Tier 1, 4 | `approvals.test.js`, `mobile-approval-flow.test.js` | 2 | PASS | Pending approvals count & query |
| **F2.3** | Upstream MUX Approval Protocol | Tier 3 | `streaming-approval.test.js` | 3 | PASS | WS & REST approval settlement |
| **F2.4** | Policy Persistence & Real-Time Sync | Tier 1, 3, 4 | `permissions.test.js`, `permission-prompt.test.js`, `mobile-security-guard.test.js` | 10 | PASS | Sandbox mode, git protect, session policies |
| **F3.1** | Automatic Network Reconnection (<=5s) | Tier 3, 4 | `reconnect-resync.test.js`, `mobile-network-recovery.test.js` | 2 | PASS | Reconnect <= 5000ms verified |
| **F3.2** | App Lifecycle State Resume | Tier 3, 4 | `reconnect-resync.test.js`, `mobile-network-recovery.test.js` | 2 | PASS | Resync on resumed connection |
| **F3.3** | Active Session State & Chunk Resync | Tier 3, 4 | `reconnect-resync.test.js`, `mobile-network-recovery.test.js` | 2 | PASS | Active session recovery after drop |
| **F3.4** | Graceful Degradation & Status | Tier 1, 2 | `health-and-auth.test.js`, `token-auth-boundary.test.js` | 13 | PASS | Non-intrusive error indicators, 401 handling |
| **F3.5** | Duplex Heartbeat Alignment | Tier 1 | `ping-pong.test.js` | 6 | 5 PASS / 1 FAIL | String ping vs JSON ping (Bug exposed) |
| **F4.1** | Defensive Payload & Parsing | Tier 2 | `oversized-payloads.test.js`, `session-id-boundary.test.js` | 11 | 10 PASS / 1 FAIL | 1MB/5MB payloads, whitespace ID (Bug exposed) |
| **F4.2** | Malformed Markdown & JSON Tolerance | Tier 2 | `malformed-json.test.js` | 5 | PASS | Syntax errors, non-object JSON |
| **F4.3** | Token Invalidation (401) Flow | Tier 1, 2 | `health-and-auth.test.js`, `token-auth-boundary.test.js` | 13 | PASS | 401 on invalid/empty/malformed tokens |
| **F4.4** | Resource Leak Prevention | Tier 1, 3 | `reconnect-resync.test.js`, `ping-pong.test.js` | 4 | PASS | Socket closure, multi-client cleanup |
| **F4.5** | Server Bridge RPC & Security Hardening | Tier 2 | `query-and-endpoints.test.js` | 5 | 4 PASS / 1 FAIL | Path traversal guard (Bug exposed) |
| **Extra** | Workspace MEMORY.md & Audit Trail | Tier 1, 4 | `workspace-memory.test.js`, `mobile-developer-memory.test.js` | 8 | 7 PASS / 1 FAIL | File persistence, audit log stub (Bug exposed) |

---

## 4. Implementation Bug Escalations (Discovered via Tests)

The following 4 defects currently exist in the Server Bridge (`dsh-server-plugin`) and must be resolved by implementing agents in Milestones M2, M3, and M4:

### Defect 1: F3.5 Raw String "ping" WebSocket Heartbeat Failure
- **Test**: `tests/e2e/tier1-features/ping-pong.test.js` (TC4)
- **Observed**: Client sending raw string `'ping'` receives no response and times out.
- **Root Cause**: `dsh-server-plugin/lib/index.js` line 1112: `ws.on('message', async (raw) => { const msg = JSON.parse(raw); ... }` parses incoming payload as JSON inside a `try {} catch (_) {}`. When a raw string `'ping'` is received, `JSON.parse('ping')` throws `SyntaxError`, which is silently swallowed.
- **Fix Required (M3)**: Inspect `raw.toString().trim()` before parsing JSON. If `msgStr === 'ping'`, respond immediately with `'pong'` or `{"type":"pong"}`.

### Defect 2: F4.1 Whitespace `sessionId` Triggers Upstream HTTP 500 RPC Crash
- **Test**: `tests/e2e/tier2-boundary/session-id-boundary.test.js` (TC2)
- **Observed**: Submitting `{ sessionId: "   ", text: "..." }` returns HTTP 500 internal server error instead of HTTP 400 Bad Request.
- **Root Cause**: `dsh-server-plugin/lib/index.js` line 932: `if (!sessionId || !text)` evaluates `"   "` as truthy. Untrimmed whitespace ID is passed to upstream DSH RPC `session/prompt`, which throws an unhandled RPC exception.
- **Fix Required (M4)**: Trim inputs defensively: `if (!sessionId?.trim() || !text?.trim()) return sendJson(400, { error: 'Missing sessionId or text' });`.

### Defect 3: F4.5 Path Traversal Vulnerability on Workspace Memory API
- **Test**: `tests/e2e/tier2-boundary/query-and-endpoints.test.js` (TC1)
- **Observed**: Requesting `GET /api/mobile/workspace/memory?workspacePath=...&fileName=../../../../Windows/win.ini` returns HTTP 200 with arbitrary filesystem access outside the workspace directory.
- **Root Cause**: `dsh-server-plugin/lib/index.js` lines 1052 & 1062: `const targetFile = path.join(wsPath, fileName);` lacks path containment checks (`path.resolve(targetFile).startsWith(path.resolve(wsPath))`).
- **Fix Required (M4)**: Validate that `path.resolve(targetFile)` is strictly within `path.resolve(wsPath)`. If not, reject with HTTP 403 Forbidden.

### Defect 4: F2.4 / Audit Logging Stubbed Out in Plugin Store
- **Test**: `tests/e2e/tier4-workloads/mobile-developer-memory.test.js` (MW-5-Audit)
- **Observed**: Audit log query always returns `[]` even after modifying memory, approvals, or permissions.
- **Root Cause**: `dsh-server-plugin/lib/store.mjs` lines 96-97:
  ```javascript
  export function audit() {}
  export function readAudit() { return []; }
  ```
- **Fix Required (M2)**: Implement persistent audit event queue in `lib/store.mjs` that records action timestamp, IP, details, and returns recent records via `readAudit(limit)`.

---

## 5. Verification Instructions

To independently verify the test suite and reproduce the results:
```bash
# From repository root:
node --test --test-concurrency=1 "tests/e2e/**/*.test.js"
```
The test run will report:
- 89 tests passing
- 4 tests failing with exact assertions corresponding to Defects 1–4 above.
