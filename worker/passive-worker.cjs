const { createHash } = require('node:crypto');
const { readFile, rename, stat, writeFile } = require('node:fs/promises');
const { createRequire } = require('node:module');
const { setTimeout: delay } = require('node:timers/promises');

const STATE = '/state';
const JOB = '/inventory/inventory.json';
const JOIN_KEY = '/run/secrets/worker-join-key';
const WORKER_NAME = 'OASM Passive Inventory';
const CORE = 'core-api:16276';

async function readOptional(path) {
  try {
    return await readFile(path, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return '';
  }
}

async function save(path, value) {
  await writeFile(path + '.tmp', value, { mode: 0o600 });
  await rename(path + '.tmp', path);
}

function event(action, fields = {}) {
  console.log(JSON.stringify({
    '@timestamp': new Date().toISOString(),
    event: { dataset: 'oasm.passive_inventory', action },
    ...fields,
  }));
}

function presenceClient() {
  const requireApi = createRequire('/app/package.json');
  const grpc = requireApi('@grpc/grpc-js');
  const requireGrpc = createRequire(requireApi.resolve('@grpc/grpc-js'));
  const definition = requireGrpc('@grpc/proto-loader').loadSync('/app/dist/proto/workers.proto');
  const { Join, Alive } = grpc.loadPackageDefinition(definition).workers.WorkersService.service;
  const Presence = grpc.makeGenericClientConstructor({ Join, Alive }, 'WorkerPresence');
  return new Presence(CORE, grpc.credentials.createInsecure());
}

async function join(client, signal) {
  const savedToken = (await readOptional(STATE + '/worker-token')).trim();
  const apiKey = savedToken ? '' : (await readFile(JOIN_KEY, 'utf8')).trim();
  if (!savedToken && !apiKey) throw new Error('Worker join key is empty');
  const identity = await new Promise((resolve, reject) => {
    const request = {
      apiKey,
      token: savedToken || undefined,
      metadata: { name: WORKER_NAME, os: 'linux', mode: 1 },
    };
    const call = client.Join(request, { deadline: Date.now() + 5000 }, (error, result) => {
      signal.removeEventListener('abort', cancel);
      if (error) reject(error);
      else resolve(result);
    });
    const cancel = () => call.cancel();
    signal.addEventListener('abort', cancel, { once: true });
    if (signal.aborted) cancel();
  });
  if (!identity.workerToken || !identity.workerId) throw new Error('Incomplete worker registration');
  await save(STATE + '/worker-token', identity.workerToken + '\n');
  return identity;
}

function keepAlive(client, identity, signal) {
  return new Promise((resolve, reject) => {
    const call = client.Alive({ workerToken: identity.workerToken });
    const cancel = () => call.cancel();
    const cleanup = () => signal.removeEventListener('abort', cancel);
    let online = false;
    call.on('data', response => {
      if (response.alive && !online) {
        online = true;
        event('worker.online', { worker: { id: identity.workerId, name: WORKER_NAME } });
      }
    });
    call.once('end', () => { cleanup(); resolve(); });
    call.once('error', error => { cleanup(); reject(error); });
    signal.addEventListener('abort', cancel, { once: true });
    if (signal.aborted) cancel();
  });
}

async function maintainPresence(client, signal) {
  while (!signal.aborted) {
    try {
      const identity = await join(client, signal);
      await keepAlive(client, identity, signal);
    } catch (error) {
      if (!signal.aborted) event('worker.connection_error', { error: { code: error.code ?? 'configuration' } });
    }
    if (!signal.aborted) await delay(5000, undefined, { signal });
  }
}

function normalized(item) {
  if (!item || typeof item !== 'object') return false;
  return [item.ecosystem, item.name, item.version].every(value =>
    typeof value === 'string' && value.length <= 200 && value.trim() === value && value.length > 0);
}

function matchInventory(input) {
  if (!Array.isArray(input?.packages) || !Array.isArray(input?.advisories)) {
    throw new Error('Expected packages and advisories arrays');
  }
  const advisories = new Map();
  for (const item of input.advisories) {
    if (!normalized(item) || typeof item.cve !== 'string' || !/^CVE-\d{4}-\d{4,}$/.test(item.cve)) {
      throw new Error('Invalid advisory record');
    }
    const key = JSON.stringify([item.ecosystem, item.name, item.version]);
    if (!advisories.has(key)) advisories.set(key, new Set());
    advisories.get(key).add(item.cve);
  }
  const matches = new Map();
  for (const item of input.packages) {
    if (!normalized(item) || typeof item.asset_id !== 'string' || !item.asset_id.trim() || item.asset_id.length > 200) {
      throw new Error('Invalid inventory record');
    }
    const { asset_id, ecosystem, name, version } = item;
    const key = JSON.stringify([ecosystem, name, version]);
    for (const cve of advisories.get(key) ?? []) {
      const match = { asset_id, ecosystem, name, version, cve };
      matches.set(JSON.stringify(match), match);
    }
  }
  return [...matches.values()];
}

async function watchInventory(signal) {
  const resultPath = STATE + '/inventory-results.json';
  let previous = JSON.parse(await readOptional(resultPath) || '{}').job_id;
  let failed = '';
  while (!signal.aborted) {
    try {
      const size = await stat(JOB).then(file => file.size).catch(error => {
        if (error.code === 'ENOENT') return 0;
        throw error;
      });
      if (size > 0) {
        if (size > 2 * 1024 * 1024) throw new Error('Inventory file exceeds 2 MiB');
        const input = await readFile(JOB, 'utf8');
        const id = createHash('sha256').update(input).digest('hex');
        if (id !== previous) {
          const inventory = JSON.parse(input);
          const matches = matchInventory(inventory);
          await save(resultPath, JSON.stringify({ job_id: id, matches }, null, 2) + '\n');
          previous = id;
          event('inventory.completed', { job_id: id, packages: inventory.packages.length, matches: matches.length });
        }
      }
      failed = '';
    } catch (error) {
      const reason = error instanceof SyntaxError ? 'Invalid inventory JSON' : error.message;
      if (failed !== reason) event('inventory.failed', { error: { message: reason } });
      failed = reason;
    }
    await delay(10000, undefined, { signal });
  }
}

async function main() {
  const controller = new AbortController();
  const { signal } = controller;
  for (const name of ['SIGINT', 'SIGTERM']) process.once(name, () => controller.abort());
  const client = presenceClient();
  try {
    await Promise.all([maintainPresence(client, signal), watchInventory(signal)]);
  } catch (error) {
    if (!signal.aborted || error.name !== 'AbortError') throw error;
  } finally {
    controller.abort();
    client.close();
  }
}

if (require.main === module) {
  main().catch(error => {
    event('worker.failed', { error: { code: error.code ?? 'configuration' } });
    process.exitCode = 1;
  });
}

module.exports = { matchInventory };
