import { connection } from '@kit.NetworkKit';

export interface PhysicalDnsSnapshot {
  networkId: number;
  resolvers: string[];
}

// getDefaultNet explicitly excludes VPN networks. Never read the VPN link's
// resolver list as the base for Quad100, which would create a forwarding loop.
export class PhysicalDnsService {
  static async read(): Promise<PhysicalDnsSnapshot> {
    const before: connection.NetHandle = await connection.getDefaultNet();
    if (before.netId === 0) throw new Error('Physical DNS network unavailable');
    const properties: connection.ConnectionProperties = await connection.getConnectionProperties(before);
    const after: connection.NetHandle = await connection.getDefaultNet();
    if (before.netId !== after.netId) throw new Error('Physical DNS network changed');
    const resolvers: string[] = [];
    for (const address of properties.dnses ?? []) {
      const value: string = address.address;
      if (typeof value !== 'string' || value.length === 0 || value.length > 128 ||
        value === '100.100.100.100' || value === 'fd7a:115c:a1e0::53') continue;
      if (!resolvers.includes(value)) resolvers.push(value);
    }
    if (resolvers.length > 64) throw new Error('Physical DNS resolvers unavailable');
    return { networkId: before.netId, resolvers: resolvers };
  }
}
