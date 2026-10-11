/**
 * 应用主题：颜色与尺寸集中在此，禁止在页面里散落色值字面量。
 */
export class AppTheme {
  // ---------------------------------------------------------------- 颜色
  static readonly PRIMARY: string = '#3B6FE0';
  static readonly PRIMARY_LIGHT: string = '#E8EFFC';

  static readonly BG_PAGE: string = '#F5F6F8';
  static readonly BG_CARD: string = '#FFFFFF';
  static readonly BG_MASK: string = '#66000000';

  static readonly TEXT_PRIMARY: string = '#1A1A1A';
  static readonly TEXT_SECONDARY: string = '#666666';
  static readonly TEXT_HINT: string = '#999999';
  static readonly TEXT_ON_PRIMARY: string = '#FFFFFF';

  static readonly DIVIDER: string = '#EBEBEB';
  static readonly DANGER: string = '#D33A2C';
  static readonly SUCCESS: string = '#1B9C4B';

  /** 阅读页背景（跟随主题时由 ReaderTheme 提供） */
  static readonly READER_THEMES: string[] = ['light', 'sepia', 'eye_care', 'dark'];

  // ---------------------------------------------------------------- 尺寸
  static readonly PAGE_PADDING: number = 16;
  static readonly CARD_RADIUS: number = 12;
  static readonly ITEM_RADIUS: number = 8;
  static readonly GAP_S: number = 8;
  static readonly GAP_M: number = 12;
  static readonly GAP_L: number = 16;

  static readonly FONT_TITLE: number = 20;
  static readonly FONT_SUBTITLE: number = 16;
  static readonly FONT_BODY: number = 14;
  static readonly FONT_CAPTION: number = 12;

  /** 书架网格列数 */
  static readonly SHELF_COLUMNS: number = 3;
  /** 网格项封面宽高比（宽 : 高 = 3 : 4） */
  static readonly COVER_ASPECT: number = 4 / 3;
}

/**
 * 阅读页配色。与 AppTheme 分开：它需要"背景 + 正文 + 次要文字"三者成套，
 * 且要支持夜间模式。
 */
export class ReaderTheme {
  bg: string = '#FFFFFF';
  text: string = '#1A1A1A';
  secondary: string = '#888888';
  /** 顶栏/底栏浮层背景 */
  barBg: string = '#F2FFFFFF';

  static of(theme: string): ReaderTheme {
    const t = new ReaderTheme();
    if (theme === 'dark') {
      t.bg = '#111111';
      t.text = '#C8C8C8';
      t.secondary = '#777777';
      t.barBg = '#F2202020';
    } else if (theme === 'sepia') {
      t.bg = '#F5EDE0';
      t.text = '#3E3226';
      t.secondary = '#8A7A66';
      t.barBg = '#F2F5EDE0';
    } else if (theme === 'eye_care') {
      t.bg = '#CCE8CF';
      t.text = '#2B3A2E';
      t.secondary = '#5F7563';
      t.barBg = '#F2CCE8CF';
    }
    return t;
  }
}
