# TEST_INFRA: DSH Mobile & Server Bridge E2E Testing Infrastructure

## 1. Architecture Overview

This test suite provides requirement-driven, opaque-box and grey-box End-to-End (E2E) verification for the **DSH Mobile Ecosystem**, consisting of:
- **DSH Server Bridge (`dsh-server-plugin`)**: Node.js gateway running on port `3088` (providing HTTP REST API and `/mobile-ws` WebSocket duplex streaming).
- **DSH Core Engine**: Upstream AI engine listening on port `3080` (managing sessions, LLM prompts, tool execution, and approval requests).
- **Mobile Client Interface (`dsh_mobile`)**: Flutter client consuming the REST and WebSocket contracts.

### Test Runner Invocation
```bash
# Execute entire E2E test suite
node --test "tests/e2e/**/*.test.js"

# Execute specific tier
node --test "tests/e2e/tier1-features/**/*.test.js"
node --test "tests/e2e/tier2-boundary/**/*.test.js"
node --test "tests/e2e/tier3-cross-feature/**/*.test.js"
node --test "tests/e2e/tier4-workloads/**/*.test.js"
```

### Technology Stack
- **Runtime**: Node.js 20+ (Active runner: Node.js v24.14.0).
- **Test Runner**: Built-in `node:test` (`describe`, `it`, `before`, `after`, `beforeEach`, `afterEach`).
- **Assertions**: Built-in `node:assert/strict`.
- **Transports**: Native global `fetch` (HTTP) and native global `WebSocket` (RFC 6455 duplex streaming). Zero external testing dependencies required.

---

## 2. Testing Methodology

### 2.1 Category-Partition Method
Endpoints and features are partitioned into discrete parameter domains:
1. **Authentication Mode**: Bearer header, `x-dsh-token` header, query param `?token=`, `x-auth-code` header, unauthenticated.
2. **Session Lifecycle**: Creation, model binding, prompt submission, status tracking, cancellation, deletion.
3. **Approval Lifecycle**: Pending query, one-tap approval (`allowed-once` / `allow`), rejection (`rejected` / `reject`), reason propagation.
4. **Permissions Configuration**: Global policy (`ask`, `auto-read`, `danger-full-access`), sandbox mode (`workspace-write`), git protection (`protectGit`), session policy overrides.
5. **WebSocket Messaging**: Connection handshake, subscribe session, heartbeat ping/pong (string vs JSON), approval stream, in-flight streaming.

### 2.2 Boundary Value Analysis (BVA)
1. **Tokens**: Empty string (`""`), whitespace (`"   "`), unauthorized token, oversized token string, token with SQL/shell meta-characters.
2. **Session IDs**: Empty session ID, non-existent UUID (`00000000-0000-0000-0000-000000000000`), unicode strings, extremely long IDs (10,000 chars).
3. **Payloads**: Zero-byte body on POST, 1MB prompt payload, 5MB prompt payload, deep nesting JSON objects, circular/broken JSON.
4. **Path & Parameters**: Unencoded query parameters, URI path traversal (`../../etc/passwd`, `..\..\windows\win.ini`), non-existent endpoints (HTTP 404).

### 2.3 Pairwise & Cross-Feature Combinations
1. **Streaming + Approval**: Active prompt generation initiating a tool call requiring explicit approval.
2. **Disconnect + Reconnect + Resync**: Abrupt TCP drop during in-flight generation, reconnecting within 5 seconds, verifying session state resync.
3. **Permission Toggle + Prompt Flow**: Changing execution policy from `ask` to `danger-full-access` and verifying prompt execution behavior.
4. **Multi-Client Broadcast**: Dual mobile clients connected simultaneously; verifying permission updates and approval resolutions propagate to both clients.
5. **Session Model Switch + Execution**: Switching model per session and verifying execution integrity and state preservation.

### 2.4 Real-World Mobile Workloads
Five multi-step end-to-end user journeys simulating authentic mobile app interactions:
1. **MW-1: Mobile Full Lifecycle Journey**: Launch app -> verify health/token -> list workspaces -> inspect sessions -> switch model -> submit prompt -> cancel turn -> verify session history.
2. **MW-2: Mobile Approval Flow**: Connect client -> subscribe to session -> query pending approvals -> authorize tool execution -> verify audit log record.
3. **MW-3: Network Resilience & Recovery**: Connect WebSocket -> start session work -> simulate connection drop -> auto-reconnect -> verify in-flight session resync.
4. **MW-4: Security & Permissions Management**: Read security policies -> toggle git protection -> update sandbox mode -> override session-specific policy -> verify persistent state.
5. **MW-5: Developer Workspace & Memory Management**: Open workspace -> fetch `MEMORY.md` / `USER.MD` -> update workspace guidelines -> verify file persistence and audit log entry.

---

## 3. Feature Inventory & Test Matrix

| Feature ID | Feature Name | Tier | Test File | Target Coverage |
|---|---|---|---|---|
| F1.1 - F1.5 | Ergonomics & UI Stream Contract | Tier 1, 3, 4 | `prompt-and-cancel.test.js`, `reconnect-resync.test.js` | Status broadcast, prompt cancellation, streaming |
| F2.1 - F2.4 | Approvals & Permissions Stream | Tier 1, 3, 4 | `approvals.test.js`, `permissions.test.js`, `streaming-approval.test.js` | List, approve, reject, session policy, git protect |
| F3.1 - F3.5 | Network Resilience & Lifecycle | Tier 1, 3, 4 | `ping-pong.test.js`, `reconnect-resync.test.js`, `mobile-network-recovery.test.js` | Heartbeat ping/pong, reconnect <=5s, session resync |
| F4.1 - F4.5 | Defensive Robustness & Bug Hunting | Tier 1, 2 | `tier2-boundary/*.test.js`, `health-and-auth.test.js` | Token invalidation (401), path traversal, body limits |

---

## 4. Expected Output Derivation

All expected values are derived from authoritative specifications:
1. **`ORIGINAL_REQUEST.md`**: Core requirements R1 (Ergonomics), R2 (Approvals), R3 (Resilience), R4 (Defensive Robustness).
2. **`PROJECT.md`**: REST API contracts (`/api/mobile/*`) and WebSocket event schemas (`/mobile-ws`).
3. **Live Server Bridge Reference (`dsh-server-plugin` on port 3088)**: Authoritative runtime behavior, error codes, and known contract nuances.
4. **Known Discrepancies & Escalations**: Discrepancies between the specification and current implementation (such as raw string ping handling or audit log key names) are treated as test assertions that highlight areas requiring implementation fixes.

---

## 5. Test Suite Directory Layout

```
tests/e2e/
├── helpers/
│   ├── client.js                   # Reusable REST & WebSocket test client with async waiters
│   └── fixtures.js                 # Configuration constants, tokens, and test payloads
├── tier1-features/
│   ├── health-and-auth.test.js     # Health probe, token auth headers, 401 unauthenticated
│   ├── ping-pong.test.js           # REST ping, WS heartbeat, JSON ping, string ping
│   ├── sessions.test.js            # Workspace list, session query, session create, session delete
│   ├── prompt-and-cancel.test.js   # Session prompt, cancellation, session status broadcast
│   ├── approvals.test.js           # Pending approvals list, allow once, reject
│   ├── permissions.test.js         # Security policies get/post, session policy, git protect
│   ├── models-and-settings.test.js # Available models query, global model update, session model
│   └── workspace-memory.test.js    # Workspace MEMORY.md read/write, audit log verification
├── tier2-boundary/
│   ├── token-auth-boundary.test.js # Empty token, invalid token, special chars in token, 401 handling
│   ├── session-id-boundary.test.js # Empty session ID, non-existent UUID, special characters
│   ├── oversized-payloads.test.js  # 1MB/5MB prompt payloads, oversized memory file
│   ├── malformed-json.test.js      # Broken JSON syntax, non-object JSON, empty POST body
│   └── query-and-endpoints.test.js # Unencoded params, path traversal, 404 non-existent routes
├── tier3-cross-feature/
│   ├── streaming-approval.test.js  # Prompt session interaction with approval stream
│   ├── reconnect-resync.test.js    # WS disconnect -> reconnect within 5s -> session state resync
│   ├── permission-prompt.test.js   # Execution policy changes and prompt submission
│   ├── model-session-lifecycle.test.js # Session creation -> model switch -> prompt -> cancel -> delete
│   └── multi-client-broadcast.test.js # Dual mobile clients receiving simultaneous broadcasts
└── tier4-workloads/
    ├── mobile-full-lifecycle.test.js    # MW-1: Complete mobile user session journey
    ├── mobile-approval-flow.test.js     # MW-2: Mobile tool approval workflow
    ├── mobile-network-recovery.test.js  # MW-3: Cellular network drop and state recovery
    ├── mobile-security-guard.test.js    # MW-4: Mobile security policy management
    └── mobile-developer-memory.test.js  # MW-5: Mobile developer workspace memory management
```
