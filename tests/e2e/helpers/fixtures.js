/**
 * E2E Test Suite Fixtures & Configuration
 *
 * The bridge token is read from the local DSH config at runtime — it is never
 * hard-coded here. Set DSH_TOKEN in the environment to override, otherwise the
 * value is read from ~/.dsh/mobile-bridge/config.json (falling back to
 * DSH_AUTH_TOKEN). This keeps credentials out of the repository.
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

function resolveToken() {
  if (process.env.DSH_TOKEN?.trim()) return process.env.DSH_TOKEN.trim();
  if (process.env.DSH_AUTH_TOKEN?.trim()) return process.env.DSH_AUTH_TOKEN.trim();
  try {
    const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
    const cfg = JSON.parse(fs.readFileSync(path.join(home, 'mobile-bridge', 'config.json'), 'utf8'));
    if (cfg?.token) return String(cfg.token).trim();
  } catch { /* fall through */ }
  return '';
}

export const CONFIG = {
  BASE_URL: process.env.BRIDGE_URL || 'http://127.0.0.1:3088',
  WS_URL: process.env.BRIDGE_WS_URL || 'ws://127.0.0.1:3088/mobile-ws',
  VALID_TOKEN: resolveToken(),
  INVALID_TOKEN: 'invalid_token_xyz_999',
  EMPTY_TOKEN: '',
  TIMEOUT_MS: 10000
};

export const MOCK_PAYLOADS = {
  SAMPLE_PROMPT: 'Hello DSH Mobile Bridge E2E Test',
  SAMPLE_FILE_NAME: 'TEST_MEMORY.MD',
  SAMPLE_MEMORY_CONTENT: '# Test Guidelines\nCreated by E2E test runner.\n',
  OVERSIZED_PROMPT_1MB: 'A'.repeat(1024 * 1024), // 1MB text
  OVERSIZED_PROMPT_5MB: 'B'.repeat(5 * 1024 * 1024), // 5MB text
  MALFORMED_JSON_STRINGS: [
    '{"sessionId": "123", "text": ',
    '{invalid json',
    '{"unclosed": "string',
    'null',
    '12345'
  ]
};
