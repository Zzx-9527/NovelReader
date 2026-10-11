import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { StorageBootstrap } from '../common/StorageBootstrap';
import { SettingsService } from '../data/service/SettingsService';
import { Logger } from '../common/utils/Logger';
import { LogTag } from '../common/constants/AppConstants';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // 存储底座：注入 Context 并开始初始化（不阻塞窗口创建）。
    // 页面在数据访问前会 await 各自的 ensureReady()，所以不存在"UI 抢跑"问题。
    StorageBootstrap.bootstrap(this.context);

    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // 阅读进度由阅读页自己结算；这里兜底把设置落盘
    SettingsService.getInstance().flushNow().catch((e: Object) => {
      Logger.error(LogTag.SETTINGS, `设置落盘失败: ${Logger.errText(e)}`);
    });
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
