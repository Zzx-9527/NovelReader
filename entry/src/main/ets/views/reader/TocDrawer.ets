import { Chapter } from '../../model/Chapter';
import { AppColor, AppTheme, ReaderTheme } from '../../common/theme/AppTheme';

/** 目录抽屉：章节列表 + 当前章高亮。currentIndex 需 @Prop 才能随阅读位置更新高亮。 */
@Component
export struct TocDrawer {
  chapters: Chapter[] = [];
  @Prop currentIndex: number = -1;
  theme: ReaderTheme = new ReaderTheme();
  onSelect?: (chapterIndex: number) => void;
  onClose?: () => void;

  build() {
    Column() {
      Row() {
        Text(`目录（${this.chapters.length} 章）`)
          .fontSize(AppTheme.FONT_SUBTITLE)
          .fontColor(this.theme.text)
          .layoutWeight(1)
        Text('关闭')
          .fontSize(AppTheme.FONT_CAPTION)
          .fontColor(this.theme.secondary)
          .padding(8)
          .onClick(() => {
            if (this.onClose !== undefined) {
              this.onClose();
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 12, bottom: 8 })

      Divider().color(AppColor.divider)

      List() {
        ForEach(this.chapters, (chapter: Chapter) => {
          ListItem() {
            Row() {
              Text(chapter.title.length > 0 ? chapter.title : `第 ${chapter.displayNumber()} 章`)
                .fontSize(AppTheme.FONT_BODY)
                .fontColor(chapter.chapterIndex === this.currentIndex
                  ? AppColor.brand
                  : this.theme.text)
                .fontWeight(chapter.chapterIndex === this.currentIndex
                  ? FontWeight.Medium
                  : FontWeight.Normal)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(chapter.chapterIndex === this.currentIndex
              ? AppColor.brandContainer
              : this.theme.bg)
            .onClick(() => {
              if (this.onSelect !== undefined) {
                this.onSelect(chapter.chapterIndex);
              }
            })
          }
        }, (chapter: Chapter) => `${chapter.chapterIndex}_${chapter.title}`)
      }
      .layoutWeight(1)
      .width('100%')
      .cachedCount(6)
    }
    .width('78%')
    .height('100%')
    .backgroundColor(this.theme.bg)
  }
}
