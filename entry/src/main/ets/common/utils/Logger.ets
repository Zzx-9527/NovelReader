import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;

/** 统一日志封装，避免各处硬编码 domain，也便于统一过滤 */
export class Logger {
  static debug(tag: string, message: string): void {
    hilog.debug(DOMAIN, tag, '%{public}s', message);
  }

  static info(tag: string, message: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', message);
  }

  static error(tag: string, message: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', message);
  }

  /** 把捕获到的异常转成可读文案（ArkTS 里 catch 到的是 Object，不能直接当 Error 用） */
  static errText(e: Object): string {
    const err = e as Error;
    if (err !== null && err !== undefined && err.message !== undefined && err.message !== null) {
      return err.message;
    }
    return JSON.stringify(e);
  }
}
