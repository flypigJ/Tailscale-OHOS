/**
 * Boundary only: M9C intentionally has no SecretStore consumer or platform
 * implementation. Do not introduce Asset Store, HUKS, persistence, identity,
 * or login behavior until a separate milestone has a concrete consumer.
 */
export interface SecretStore {
  read(key: string): Promise<string | undefined>;
  write(key: string, value: string): Promise<boolean>;
  remove(key: string): Promise<boolean>;
}
