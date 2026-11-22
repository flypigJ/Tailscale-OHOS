import { createHash } from 'node:crypto';
const prefix=process.argv[2] ?? '';
if(!/^[a-fA-F0-9]{12}$/.test(prefix)){
  process.stderr.write('Usage: node scripts/hash-disco-tx.mjs <12 hex digits from tx=...>\n');process.exitCode=1;
}else{
  const hash=createHash('sha256').update('mesharc-disco-tx-v1:').update(Buffer.from(prefix,'hex')).digest('hex').slice(0,24);
  process.stdout.write(hash+'\n');
}
