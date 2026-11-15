#!/usr/bin/env node
// Haalt bij het opstarten van de container de nieuwste tiles op.
//
//   colombia.mbtiles          ColombiaTransit/colombia-mbtiles, release planetiler-latest
//   colombia-terrain.mbtiles  ColombiaTransit/colombia-height, release latest (in 3 delen)
//
// Per bestand: checksum van de release vergelijken met de opgeslagen
// <bestand>.sha256. Alleen bij verschil of als het bestand ontbreekt wordt
// gedownload, naar een tijdelijk bestand naast het origineel; pas na een
// geldige checksum wordt het vervangen. Lukt een update niet terwijl er al
// een bestand is, dan start de tileserver met de oude versie.
//
// Omgeving:
//   TILES_UPDATE=false    niets ophalen (alleen controleren dat de bestanden er zijn)
//   DATA_DIR              standaard /data
//   VECTOR_BASE_URL       standaard de planetiler-latest release
//   TERRAIN_MANIFEST_URL  standaard het manifest van de latest release

import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { access, constants, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { once } from 'node:events';
import http from 'node:http';
import https from 'node:https';

const DATA_DIR = process.env.DATA_DIR || '/data';
const UPDATE = (process.env.TILES_UPDATE || 'true').toLowerCase() !== 'false';
const VECTOR_BASE_URL = process.env.VECTOR_BASE_URL
  || 'https://github.com/ColombiaTransit/colombia-mbtiles/releases/download/planetiler-latest';
const TERRAIN_MANIFEST_URL = process.env.TERRAIN_MANIFEST_URL
  || 'https://github.com/ColombiaTransit/colombia-height/releases/latest/download/colombia-terrain.manifest.json';

const VECTOR_FILE = 'colombia.mbtiles';
const TERRAIN_FILE = 'colombia-terrain.mbtiles';

const log = (...a) => console.log(`[tiles] ${new Date().toISOString()}`, ...a);
const short = (h) => (h || '').slice(0, 12);

async function exists(p) {
  try { return (await stat(p)).size > 0; } catch { return false; }
}

async function storedSum(file) {
  try { return (await readFile(join(DATA_DIR, `${file}.sha256`), 'utf8')).trim().split(/\s+/)[0]; }
  catch { return ''; }
}

// Eenvoudige GET met redirects via node:http(s). Bewust geen fetch(): de
// ingebouwde undici crasht soms bij grote streams met backpressure.
function get(url, redirects = 10) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https:') ? https : http;
    const req = mod.get(url, { headers: { 'User-Agent': 'tileserver-docker' } }, (res) => {
      const { statusCode, headers } = res;
      if (statusCode >= 300 && statusCode < 400 && headers.location) {
        res.resume();
        if (redirects === 0) return reject(new Error(`te veel redirects voor ${url}`));
        return resolve(get(new URL(headers.location, url).toString(), redirects - 1));
      }
      if (statusCode !== 200) {
        res.resume();
        const err = new Error(`HTTP ${statusCode} voor ${url}`);
        err.status = statusCode;
        return reject(err);
      }
      resolve(res);
    });
    // Timeout bij geen verbinding of stilstand, niet op de totale duur
    req.setTimeout(60_000, () => req.destroy(new Error(`timeout voor ${url}`)));
    req.on('error', reject);
  });
}

async function getWithRetry(url, tries = 3) {
  let lastErr;
  for (let i = 1; i <= tries; i++) {
    try {
      return await get(url);
    } catch (e) {
      lastErr = e;
      if (e.status && e.status >= 400 && e.status < 500 && e.status !== 429) break;
      if (i < tries) await new Promise((r) => setTimeout(r, 5000 * i));
    }
  }
  throw lastErr;
}

async function getText(url) {
  const res = await getWithRetry(url);
  let body = '';
  res.setEncoding('utf8');
  for await (const chunk of res) body += chunk;
  return body;
}

// Streamt een URL naar een open schrijfstroom en houdt hashes bij.
async function streamTo(url, out, hashes) {
  const res = await getWithRetry(url);
  let bytes = 0;
  for await (const chunk of res) {
    bytes += chunk.length;
    for (const h of hashes) h.update(chunk);
    if (!out.write(chunk)) await once(out, 'drain');
  }
  return bytes;
}

async function install(file, sum, writeParts) {
  const dest = join(DATA_DIR, file);
  const tmp = join(DATA_DIR, `.${file}.downloading`);
  await rm(tmp, { force: true });
  const out = createWriteStream(tmp);
  try {
    const total = createHash('sha256');
    await writeParts(out, total);
    await new Promise((resolve, reject) => out.end((err) => (err ? reject(err) : resolve())));
    const got = total.digest('hex');
    if (got !== sum) throw new Error(`checksum klopt niet (${short(got)} i.p.v. ${short(sum)})`);
    await rename(tmp, dest);
    await writeFile(join(DATA_DIR, `${file}.sha256`), `${sum}\n`);
  } catch (e) {
    out.destroy();
    await rm(tmp, { force: true });
    throw e;
  }
}

async function updateVector() {
  const sum = (await getText(`${VECTOR_BASE_URL}/${VECTOR_FILE}.sha256`)).trim().split(/\s+/)[0];
  if (!/^[0-9a-f]{64}$/.test(sum)) throw new Error('ongeldige checksum in release');
  if (await exists(join(DATA_DIR, VECTOR_FILE)) && sum === await storedSum(VECTOR_FILE)) {
    log(`${VECTOR_FILE}: al de nieuwste (${short(sum)})`);
    return;
  }
  log(`${VECTOR_FILE}: nieuwe versie ${short(sum)}, downloaden...`);
  await install(VECTOR_FILE, sum, async (out, total) => {
    const bytes = await streamTo(`${VECTOR_BASE_URL}/${VECTOR_FILE}`, out, [total]);
    log(`${VECTOR_FILE}: ${(bytes / 1048576).toFixed(0)} MB binnen`);
  });
  log(`${VECTOR_FILE}: geïnstalleerd (${short(sum)})`);
}

async function updateTerrain() {
  const manifest = JSON.parse(await getText(TERRAIN_MANIFEST_URL));
  const sum = manifest.merged_mbtiles_sha256;
  const version = manifest.release_version;
  const parts = manifest.parts;
  if (!/^[0-9a-f]{64}$/.test(sum || '')) throw new Error('manifest zonder geldige checksum');
  if (!/^v\d+\.\d+\.\d+$/.test(version || '')) throw new Error('manifest zonder geldige versie');
  if (!Array.isArray(parts) || parts.length === 0) throw new Error('manifest zonder delen');

  if (await exists(join(DATA_DIR, TERRAIN_FILE)) && sum === await storedSum(TERRAIN_FILE)) {
    log(`${TERRAIN_FILE}: al de nieuwste ${version} (${short(sum)})`);
    return;
  }
  // Delen staan bij de vaste versie, niet bij 'latest', zodat ze bij elkaar horen
  const partBase = TERRAIN_MANIFEST_URL.replace(/\/releases\/latest\/download\/.*$/,
    `/releases/download/${version}`).replace(/\/[^/]*\.manifest\.json$/, '');
  log(`${TERRAIN_FILE}: nieuwe versie ${version} (${short(sum)}), ${parts.length} delen downloaden...`);
  await install(TERRAIN_FILE, sum, async (out, total) => {
    for (const part of parts) {
      if (!/^[A-Za-z0-9._-]+$/.test(part.file || '')) throw new Error('ongeldige deelnaam in manifest');
      const h = createHash('sha256');
      const bytes = await streamTo(`${partBase}/${part.file}`, out, [h, total]);
      const got = h.digest('hex');
      if (bytes !== part.bytes || got !== part.sha256) {
        throw new Error(`${part.file}: grootte of checksum klopt niet`);
      }
      log(`${TERRAIN_FILE}: ${part.file} geverifieerd (${(bytes / 1048576).toFixed(0)} MB)`);
    }
  });
  log(`${TERRAIN_FILE}: geïnstalleerd ${version} (${short(sum)})`);
}

async function main() {
  let writable = true;
  try {
    await access(DATA_DIR, constants.W_OK);
  } catch {
    writable = false;
    if (UPDATE) {
      log(`LET OP: ${DATA_DIR} is niet schrijfbaar voor uid ${process.getuid?.()}; updates lukken niet.`);
      log('Geef de map op de host aan uid 1000: sudo chown -R 1000:1000 ./data');
    }
  }

  let failed = false;
  if (UPDATE) {
    for (const [name, fn] of [[VECTOR_FILE, updateVector], [TERRAIN_FILE, updateTerrain]]) {
      try {
        await fn();
      } catch (e) {
        failed = true;
        log(`${name}: update mislukt: ${e.message}`);
      }
    }
  } else {
    log('TILES_UPDATE=false: geen updates ophalen');
  }

  // Zonder beide bestanden kan tileserver-gl niet starten
  const missing = [];
  for (const f of [VECTOR_FILE, TERRAIN_FILE]) {
    if (!(await exists(join(DATA_DIR, f)))) missing.push(f);
  }
  if (missing.length) {
    log(`FOUT: ontbrekend in ${DATA_DIR}: ${missing.join(', ')}. Container stopt; Docker probeert het opnieuw.`);
    if (!writable) log('Oorzaak waarschijnlijk: de datamap is niet schrijfbaar (zie hierboven).');
    process.exit(1);
  }
  if (failed) log('Start met de bestaande tiles.');
}

main();
