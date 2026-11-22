import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { userAuth } from '@kit.UserAuthenticationKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'AppSecurityAuth';
const CHALLENGE_LENGTH: number = 16;
const PREFERRED_TRUST_LEVEL: userAuth.AuthTrustLevel = userAuth.AuthTrustLevel.ATL3;
const FALLBACK_TRUST_LEVEL: userAuth.AuthTrustLevel = userAuth.AuthTrustLevel.ATL2;

interface ResolvedAuthPolicy {
  trustLevel: userAuth.AuthTrustLevel;
  authTypes: userAuth.UserAuthType[];
}

/** Uses HarmonyOS' system authentication widget; no credentials or AuthToken are retained. */
export class AppSecurityAuthenticator {
  static authenticate(title: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (passed: boolean) => void) => {
      let instance: userAuth.UserAuthInstance | undefined = undefined;
      let settled: boolean = false;
      const finish = (passed: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        try {
          instance?.off('result', callback);
        } catch (_error) {
          // Authentication has already reached a terminal state.
        }
        resolve(passed);
      };
      const callback: userAuth.IAuthCallback = {
        onResult: (result: userAuth.UserAuthResult): void => {
          hilog.info(DOMAIN, TAG, 'Authentication completed. result=%{public}d', result.result);
          finish(result.result === userAuth.UserAuthResultCode.SUCCESS);
        }
      };
      let stage: string = 'availability';
      try {
        const policy: ResolvedAuthPolicy = AppSecurityAuthenticator.resolveAuthPolicy();
        if (policy.authTypes.length === 0) {
          hilog.error(DOMAIN, TAG, 'No enrolled system authentication type is available.');
          finish(false);
          return;
        }
        stage = 'challenge';
        const challenge: Uint8Array = cryptoFramework.createRandom()
          .generateRandomSync(CHALLENGE_LENGTH).data;
        stage = 'instance';
        const authParam: userAuth.AuthParam = {
          challenge: challenge,
          authType: policy.authTypes,
          authTrustLevel: policy.trustLevel
        };
        const widgetParam: userAuth.WidgetParam = { title: title };
        instance = userAuth.getUserAuthInstance(authParam, widgetParam);
        stage = 'listener';
        instance.on('result', callback);
        stage = 'start';
        instance.start();
        hilog.info(DOMAIN, TAG,
          'System authentication widget started. typeCount=%{public}d trustLevel=%{public}d',
          policy.authTypes.length, policy.trustLevel);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.error(DOMAIN, TAG, 'Authentication setup failed. stage=%{public}s code=%{public}d',
          stage, businessError.code ?? -1);
        finish(false);
      }
    });
  }

  private static resolveAuthPolicy(): ResolvedAuthPolicy {
    const preferredTypes: userAuth.UserAuthType[] =
      AppSecurityAuthenticator.availableAuthTypesAt(PREFERRED_TRUST_LEVEL);
    if (preferredTypes.length > 0) {
      return {
        trustLevel: PREFERRED_TRUST_LEVEL,
        authTypes: preferredTypes
      };
    }
    const fallbackTypes: userAuth.UserAuthType[] =
      AppSecurityAuthenticator.availableAuthTypesAt(FALLBACK_TRUST_LEVEL);
    return {
      trustLevel: FALLBACK_TRUST_LEVEL,
      authTypes: fallbackTypes
    };
  }

  private static availableAuthTypesAt(trustLevel: userAuth.AuthTrustLevel): userAuth.UserAuthType[] {
    const candidates: userAuth.UserAuthType[] = [
      userAuth.UserAuthType.FACE,
      userAuth.UserAuthType.FINGERPRINT,
      userAuth.UserAuthType.PIN
    ];
    const available: userAuth.UserAuthType[] = [];
    candidates.forEach((authType: userAuth.UserAuthType) => {
      try {
        userAuth.getAvailableStatus(authType, trustLevel);
        available.push(authType);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.info(DOMAIN, TAG,
          'Authentication type unavailable. type=%{public}d trustLevel=%{public}d code=%{public}d',
          authType, trustLevel, businessError.code ?? -1);
      }
    });
    return available;
  }
}
