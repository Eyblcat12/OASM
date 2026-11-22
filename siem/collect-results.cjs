const { createHash } = require('node:crypto');
const { appendFile, readFile, rename, writeFile } = require('node:fs/promises');
const { isIP } = require('node:net');
const { setTimeout: delay } = require('node:timers/promises');

const OASM = process.env.OASM_BASE_URL;
const POLL_MS = 10_000;
const AUDIT_OVERLAP_MS = 120_000;
const PAGE_LIMIT = 100;
const host = { name: process.env.OASM_SOURCE_HOST };

function hash(value) {
  return createHash('sha256').update(value).digest('hex');
}

function safeUrl(value) {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol)) return undefined;
    return url.origin + url.pathname;
  } catch {
    return undefined;
  }
}

function auditDocument(row) {
  return {
    '@timestamp': row.occurredAt,
    host,
    event: { id: row.eventId, dataset: 'oasm.audit', action: row.action },
    oasm: {
      workspace: { id: row.workspaceId },
      audit: {
        actor_id: row.actorId,
        actor_type: row.actorType,
        outcome: row.outcome,
        resource_id: row.resourceId,
        resource_type: row.resourceType,
        correlation_id: row.correlationId,
      },
    },
    source: isIP(row.sourceIp) ? { ip: row.sourceIp } : undefined,
    message: row.action + ' (' + row.outcome + ')',
  };
}

function findingDocument(row, workspace) {
  const url = safeUrl(row.affectedUrl);
  return {
    '@timestamp': row.updatedAt || row.createdAt,
    host,
    event: { dataset: 'oasm.finding', action: 'finding.snapshot' },
    vulnerability: {
      id: row.cveId || row.id,
      severity: row.severity,
      score: typeof row.cvssScore === 'number' ? { base: row.cvssScore } : undefined,
    },
    oasm: {
      workspace: { id: workspace },
      finding: {
        id: row.id,
        title: row.name,
        cve_id: row.cveId,
        detection_status: row.detectionStatus,
        review_status: row.reviewStatus,
        asset_id: row.asset?.id,
        first_detected_at: row.firstDetectedDate,
        last_seen_at: row.lastSeenDate,
        fixed_at: row.fixedAt,
      },
    },
    url: url ? { full: url } : undefined,
    message: row.name || 'OASM finding',
  };
}

async function getOasm(path, connection) {
  const response = await fetch(new URL(path, OASM), {
    headers: { Cookie: connection.cookie, 'X-Workspace-ID': connection.workspace },
    redirect: 'error',
    signal: AbortSignal.timeout(8000),
  });
  if (!response.ok) throw new Error(`OASM GET ${path.split('?')[0]} returned HTTP ${response.status}`);
  const newCookies = response.headers.getSetCookie();
  if (newCookies.length > 0) {
    const cookies = new Map(connection.cookie.split(/;\s*/).map(pair => [pair.split('=', 1)[0], pair]));
    for (const header of newCookies) {
      const pair = header.split(';', 1)[0];
      cookies.set(pair.split('=', 1)[0], pair);
    }
    connection.cookie = [...cookies.values()].join('; ');
  }
  return response.json();
}

async function appendEvents(stream, records) {
  if (records.length === 0) return 0;
  const day = new Date().toISOString().slice(0, 10);
  const body = records.map(document => JSON.stringify(document)).join('\n') + '\n';
  await appendFile(`/out/oasm-${stream}-${day}.ndjson`, body, { mode: 0o640, flush: true });
  return records.length;
}

async function readAudit(connection, checkpoint, end) {
  const query = new URLSearchParams({ limit: PAGE_LIMIT, to: end });
  if (checkpoint.auditThrough) {
    query.set('from', new Date(Date.parse(checkpoint.auditThrough) - AUDIT_OVERLAP_MS).toISOString());
  }
  let received = 0;
  let inserted = 0;
  const seen = {};
  do {
    const page = await getOasm(`/api/workspaces/${connection.workspace}/audit?${query}`, connection);
    received += page.data.length;
    const records = [];
    for (const row of page.data) {
      if (!row.eventId || !row.occurredAt) throw new Error('Audit record is missing its ID or timestamp');
      if (Date.parse(row.occurredAt) >= Date.parse(end) - AUDIT_OVERLAP_MS) seen[row.eventId] = row.occurredAt;
      if (!checkpoint.auditSeen[row.eventId]) records.push(auditDocument(row));
    }
    inserted += await appendEvents('audit', records);
    if (!page.nextCursor) break;
    if (query.get('cursor') === page.nextCursor) throw new Error('The audit API repeated a cursor');
    query.set('cursor', page.nextCursor);
  } while (true);
  return { received, inserted, seen };
}

async function readFindings(connection, previous) {
  const versions = {};
  let inserted = 0;
  for (const status of ['all', 'pending_review', 'rejected']) {
    for (let pageNumber = 1; ; pageNumber += 1) {
      const query = new URLSearchParams({ status, limit: PAGE_LIMIT, page: pageNumber, sortBy: 'id' });
      const page = await getOasm(`/api/vulnerabilities?${query}`, connection);
      const records = [];
      for (const row of page.data) {
        if (!row.id || !(row.updatedAt || row.createdAt)) throw new Error('Finding is missing its ID or timestamp');
        const document = findingDocument(row, connection.workspace);
        const version = hash(JSON.stringify(document));
        versions[row.id] = version;
        if (previous[row.id] === version) continue;
        const id = hash(`${connection.workspace}:${row.id}:${version}`);
        document.event.id = id;
        records.push(document);
      }
      inserted += await appendEvents('finding', records);
      if (pageNumber >= page.pageCount || page.data.length === 0) break;
    }
  }
  return { versions, inserted };
}

async function pollDiscovery(connection, source, interval) {
  const stateFile = `/state/discovery-${source}.json`;
  const isUrl = source === 'url';
  let checkpoint = {};
  try {
    checkpoint = JSON.parse(await readFile(stateFile, 'utf-8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  let firstPass = true;
  for (;;) {
    try {
      const versions = {};
      const observed = new Date().toISOString();
      let received = 0;
      let inserted = 0;
      for (let page = 1; ; page += 1) {
        const query = new URLSearchParams({ page, limit: PAGE_LIMIT, sortBy: isUrl ? 'url' : 'id' });
        const response = await getOasm(`/api/assets${isUrl ? '/url' : ''}?${query}`, connection);
        received += response.data.length;
        const records = [];
        for (const row of response.data) {
          const discovery = isUrl ? historicalUrl(row) : discoveredService(row);
          if (!discovery) continue;
          const id = hash(`${connection.workspace}:${source}:${discovery.key}`);
          if (versions[id]) continue;
          const version = hash(JSON.stringify([discovery.fields, discovery.details]));
          versions[id] = version;
          if (checkpoint[id] === version) continue;
          const eventId = hash(`${id}:${version}`);
          const document = {
            '@timestamp': observed,
            host,
            event: { dataset: 'oasm.discovery', action: `discovery.${source}`, id: eventId },
            ...discovery.fields,
            oasm: { workspace: { id: connection.workspace }, discovery: discovery.details },
          };
          records.push(document);
        }
        inserted += await appendEvents(`discovery-${source}`, records);
        if (!response.hasNextPage || response.data.length === 0) break;
      }
      await writeFile(stateFile + '.tmp', JSON.stringify(versions), { mode: 0o600 });
      await rename(stateFile + '.tmp', stateFile);
      checkpoint = versions;
      if (firstPass || inserted) {
        console.log(`Discovery synced: source=${source} read=${received} normalized=${Object.keys(versions).length} inserted=${inserted}`);
      }
      firstPass = false;
    } catch (error) {
      console.error(`OASM discovery sync failed: source=${source} ${error.message}`);
    }
    await delay(interval);
  }
}

function historicalUrl(row) {
  const url = safeUrl(row.url);
  if (!url) return undefined;
  const hostname = new URL(url).hostname;
  return {
    key: url,
    fields: { url: { full: url, domain: hostname } },
    details: { hostname },
  };
}

function discoveredService(row) {
  if (!row.id || !row.value || !Number.isInteger(row.port) || row.port <= 0) return undefined;
  const response = row.httpResponses;
  const url = safeUrl(response?.url);
  const technologies = Array.isArray(response?.tech)
    ? [...new Set(response.tech.filter(value => typeof value === 'string'))].sort()
    : undefined;
  return {
    key: row.id,
    fields: {
      destination: { port: row.port },
      http: Number.isInteger(response?.status_code) ? { response: { status_code: response.status_code } } : undefined,
      network: response?.scheme ? { protocol: response.scheme } : undefined,
      url: url ? { full: url, domain: new URL(url).hostname } : undefined,
    },
    details: {
      hostname: row.value,
      service_id: row.id,
      target_id: row.targetId,
      ip_addresses: Array.isArray(row.ipAddresses) ? [...new Set(row.ipAddresses.filter(value => isIP(value)))].sort() : undefined,
      technologies,
    },
  };
}

async function pollSecurity(source, collect) {
  const stateFile = `/state/${source}.json`;
  let checkpoint = {};
  try {
    checkpoint = JSON.parse(await readFile(stateFile, 'utf-8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  let firstPass = true;
  for (;;) {
    try {
      const result = await collect(checkpoint);
      await writeFile(stateFile + '.tmp', JSON.stringify(result.state), { mode: 0o600 });
      await rename(stateFile + '.tmp', stateFile);
      checkpoint = result.state;
      if (firstPass || result.inserted) {
        console.log(`Sync complete: source=${source} read=${result.received} appended=${result.inserted}`);
      }
      firstPass = false;
    } catch (error) {
      console.error(`OASM sync failed: source=${source} ${error.message}`);
    }
    await delay(POLL_MS);
  }
}

async function main() {
  const connection = JSON.parse(await readFile('/run/secrets/sync-connection', 'utf-8'));
  const endpoint = new URL(OASM);
  if (!['http:', 'https:'].includes(endpoint.protocol) || endpoint.username || endpoint.password ||
      endpoint.pathname !== '/' || endpoint.search || endpoint.hash || !host.name) {
    throw new Error('Set OASM_BASE_URL to an HTTP(S) origin and set OASM_SOURCE_HOST');
  }
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(connection.workspace) ||
      typeof connection.cookie !== 'string' || !connection.cookie.trim() || /[\r\n]/.test(connection.cookie)) {
    throw new Error('The connection file needs a workspace UUID and an OASM session cookie');
  }
  await Promise.all([
    pollSecurity('audit', async checkpoint => {
      const end = new Date().toISOString();
      const result = await readAudit(connection, { auditSeen: {}, ...checkpoint }, end);
      return { ...result, state: { auditThrough: end, auditSeen: result.seen } };
    }),
    pollSecurity('finding', async checkpoint => {
      const result = await readFindings(connection, checkpoint);
      return { ...result, received: Object.keys(result.versions).length, state: result.versions };
    }),
    pollDiscovery(connection, 'service', 30_000),
    pollDiscovery(connection, 'url', 300_000),
  ]);
}

main().catch(error => {
  console.error(`OASM security sync could not start: ${error.message}`);
  process.exitCode = 1;
});
