export interface MoonlightIntegrationConfig {
  bundleName: string;
  abilityName: string;
  moduleName: string;
  protocolVersion: number;
  capabilityUri: string;
}

// The v1 capability is advertised only by Moonlight builds that accept this Want.
export const MOONLIGHT_INTEGRATION_CONFIG: MoonlightIntegrationConfig = {
  bundleName: 'com.alkaidlab.sdream',
  abilityName: 'EntryAbility',
  moduleName: 'entry',
  protocolVersion: 1,
  capabilityUri: 'moonlight-mesharc://host'
};
