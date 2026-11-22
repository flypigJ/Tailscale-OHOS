import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type NavigationTabId = 'home' | 'transfer' | 'files' | 'settings';

export interface NavigationSettings {
  order: NavigationTabId[];
  hidden: NavigationTabId[];
  bottomMargin: number;
}

export const DEFAULT_NAVIGATION_ORDER: NavigationTabId[] = ['home', 'transfer', 'files', 'settings'];
export const DEFAULT_NAVIGATION_HIDDEN: NavigationTabId[] = [];
export const DEFAULT_NAVIGATION_BOTTOM_MARGIN: number = 30;

const STORE_NAME: string = 'mesh_arc_navigation';
const ORDER_KEY: string = 'navigation_order';
const HIDDEN_KEY: string = 'navigation_hidden';
const BOTTOM_MARGIN_KEY: string = 'navigation_bottom_margin';

/** Persists the app's primary navigation order, visibility, and floating position. */
export class NavigationPreferences {
  static defaults(): NavigationSettings {
    return {
      order: [...DEFAULT_NAVIGATION_ORDER],
      hidden: [...DEFAULT_NAVIGATION_HIDDEN],
      bottomMargin: DEFAULT_NAVIGATION_BOTTOM_MARGIN
    };
  }

  static async load(context: common.Context): Promise<NavigationSettings> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const order: string = store.getSync(ORDER_KEY, DEFAULT_NAVIGATION_ORDER.join(',')) as string;
      const hidden: string = store.getSync(HIDDEN_KEY, '') as string;
      const bottomMargin: number = store.getSync(
        BOTTOM_MARGIN_KEY, DEFAULT_NAVIGATION_BOTTOM_MARGIN) as number;
      return NavigationPreferences.normalize(order, hidden, bottomMargin);
    } catch (_error) {
      return NavigationPreferences.defaults();
    }
  }

  static async save(context: common.Context, settings: NavigationSettings): Promise<void> {
    const normalized: NavigationSettings = NavigationPreferences.normalize(
      settings.order.join(','), settings.hidden.join(','), settings.bottomMargin);
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(ORDER_KEY, normalized.order.join(','));
    store.putSync(HIDDEN_KEY, normalized.hidden.join(','));
    store.putSync(BOTTOM_MARGIN_KEY, normalized.bottomMargin);
    await store.flush();
  }

  private static normalize(orderValue: string, hiddenValue: string,
    bottomMarginValue: number = DEFAULT_NAVIGATION_BOTTOM_MARGIN): NavigationSettings {
    const order: NavigationTabId[] = NavigationPreferences.parseList(orderValue);
    DEFAULT_NAVIGATION_ORDER.forEach((id: NavigationTabId) => {
      if (!order.includes(id)) {
        order.push(id);
      }
    });
    const hidden: NavigationTabId[] = NavigationPreferences.parseList(hiddenValue)
      .filter((id: NavigationTabId) => id !== 'settings' && order.includes(id));
    if (hidden.length >= order.length) {
      return {
        order: order,
        hidden: order.filter((id: NavigationTabId) => id !== 'home' && id !== 'settings'),
        bottomMargin: NavigationPreferences.normalizeBottomMargin(bottomMarginValue)
      };
    }
    return {
      order: order,
      hidden: hidden,
      bottomMargin: NavigationPreferences.normalizeBottomMargin(bottomMarginValue)
    };
  }

  private static normalizeBottomMargin(value: number): number {
    if (!Number.isFinite(value)) {
      return DEFAULT_NAVIGATION_BOTTOM_MARGIN;
    }
    return Math.min(100, Math.max(0, Math.round(value)));
  }

  private static parseList(value: string): NavigationTabId[] {
    const result: NavigationTabId[] = [];
    value.split(',').forEach((candidate: string) => {
      const id: string = candidate.trim();
      if (NavigationPreferences.isTabId(id) && !result.includes(id as NavigationTabId)) {
        result.push(id as NavigationTabId);
      }
    });
    return result;
  }

  private static isTabId(value: string): boolean {
    return value === 'home' || value === 'transfer' || value === 'files' || value === 'settings';
  }
}
