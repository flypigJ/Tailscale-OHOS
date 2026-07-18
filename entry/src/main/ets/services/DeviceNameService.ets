import { deviceInfo } from '@kit.BasicServicesKit';

const HUAWEI_BRAND: string = 'huawei';

export class DeviceNameService {
  static withoutHuaweiBrand(value: string): string {
    const trimmed: string = value.trim();
    const lowerValue: string = trimmed.toLowerCase();
    if (lowerValue === HUAWEI_BRAND) {
      return '';
    }
    if (lowerValue.startsWith(`${HUAWEI_BRAND} `) ||
      lowerValue.startsWith(`${HUAWEI_BRAND}-`) ||
      lowerValue.startsWith(`${HUAWEI_BRAND}_`)) {
      return trimmed.substring(HUAWEI_BRAND.length).replace(/^[\s_-]+/, '').trim();
    }
    return trimmed;
  }

  static model(): string {
    const marketName: string = DeviceNameService.withoutHuaweiBrand(deviceInfo.marketName);
    if (marketName.length > 0 && marketName !== 'default') {
      return marketName;
    }
    return DeviceNameService.withoutHuaweiBrand(deviceInfo.productModel);
  }
}
