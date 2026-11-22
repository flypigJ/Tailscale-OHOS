import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
const root = new URL('../', import.meta.url);
const files = ['AppScope/app.json5', 'entry/src/main/module.json5',
  'entry/src/main/ets/services/RuntimeDiagnosticService.ets',
  'entry/src/main/ets/services/DiagnosticEventStore.ets',
  'entry/src/main/ets/services/VpnNetworkMonitor.ets',
  'entry/src/main/ets/services/VpnBackgroundTaskManager.ets',
  'entry/src/main/ets/entryability/EntryAbility.ets',
  'entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets'];
const hash = createHash('sha256');
for (const file of files) hash.update(file + '\0').update(readFileSync(new URL(file, root), 'utf8').replace(/\r\n/g, '\n')).update('\0');
const content = '// Generated diagnostic-source fingerprint; not a signed-package identity.\n' +
  "export const RUNTIME_BUILD_FINGERPRINT: string = '" + hash.digest('hex') + "';\n";
const output = new URL('entry/src/main/ets/services/RuntimeDiagnosticBuild.ets', root);
if (process.argv.includes('--check')) {
  if (readFileSync(output, 'utf8') !== content) throw Error('Diagnostic fingerprint stale; run node scripts/update-runtime-fingerprint.mjs');
} else writeFileSync(output, content);
console.log('Diagnostic source fingerprint ' + (process.argv.includes('--check') ? 'verified' : 'updated'));
