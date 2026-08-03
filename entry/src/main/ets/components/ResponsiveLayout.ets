/**
 * Pure viewport rules shared by the app shell.  Keeping this independent of
 * device identity makes fold, landscape, and freeform window changes behave
 * the same way as ordinary resizes.
 */
export enum ResponsiveWidthClass {
  COMPACT = 'compact',
  MEDIUM = 'medium',
  EXPANDED = 'expanded'
}

export enum ResponsiveNavigationMode {
  BOTTOM = 'bottom',
  SIDE = 'side'
}

export enum HomeContentLayout {
  SINGLE_COLUMN = 'single-column',
  MASTER_DETAIL = 'master-detail'
}

export enum TransferContentLayout {
  SINGLE_COLUMN = 'single-column',
  SPLIT = 'split'
}

export enum SettingsContentLayout {
  SINGLE_COLUMN = 'single-column',
  TWO_COLUMN = 'two-column'
}

export class ResponsiveLayout {
  static readonly MEDIUM_MIN_WIDTH: number = 600;
  static readonly EXPANDED_MIN_WIDTH: number = 840;
  static readonly EXPANDED_CONTENT_MAX_WIDTH: number = 1240;
  static readonly SETTINGS_CONTENT_MAX_WIDTH: number = 760;
  static readonly MASTER_PANEL_WIDTH: number = 344;

  static widthClass(width: number): ResponsiveWidthClass {
    if (width >= ResponsiveLayout.EXPANDED_MIN_WIDTH) {
      return ResponsiveWidthClass.EXPANDED;
    }
    if (width >= ResponsiveLayout.MEDIUM_MIN_WIDTH) {
      return ResponsiveWidthClass.MEDIUM;
    }
    return ResponsiveWidthClass.COMPACT;
  }

  static pageMargin(width: number): number {
    if (width >= ResponsiveLayout.EXPANDED_MIN_WIDTH) {
      return 32;
    }
    if (width >= ResponsiveLayout.MEDIUM_MIN_WIDTH) {
      return 24;
    }
    return 16;
  }

  static usesSideNavigation(width: number): boolean {
    return width >= ResponsiveLayout.MEDIUM_MIN_WIDTH;
  }

  /**
   * Home keeps the existing 600/840 width breakpoints.  Between them, a
   * landscape or square window has enough horizontal room for side input;
   * a portrait window retains the bottom input used by phones.
   */
  static homeNavigationMode(width: number, height: number): ResponsiveNavigationMode {
    if (width >= ResponsiveLayout.EXPANDED_MIN_WIDTH) {
      return ResponsiveNavigationMode.SIDE;
    }
    if (width >= ResponsiveLayout.MEDIUM_MIN_WIDTH && width >= height) {
      return ResponsiveNavigationMode.SIDE;
    }
    return ResponsiveNavigationMode.BOTTOM;
  }

  static homeContentLayout(width: number): HomeContentLayout {
    return width >= ResponsiveLayout.EXPANDED_MIN_WIDTH
      ? HomeContentLayout.MASTER_DETAIL : HomeContentLayout.SINGLE_COLUMN;
  }

  static transferContentLayout(width: number): TransferContentLayout {
    return width >= ResponsiveLayout.EXPANDED_MIN_WIDTH
      ? TransferContentLayout.SPLIT : TransferContentLayout.SINGLE_COLUMN;
  }

  static settingsContentLayout(width: number): SettingsContentLayout {
    return width >= ResponsiveLayout.EXPANDED_MIN_WIDTH
      ? SettingsContentLayout.TWO_COLUMN : SettingsContentLayout.SINGLE_COLUMN;
  }
}
