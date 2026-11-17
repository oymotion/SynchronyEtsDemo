import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import window from '@ohos.window';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import { SensorController, setBridge } from 'sensor';

const TAG: string = 'SensorEtsDemo';
const DOMAIN: number = 0xE001;

function pad2(v: number): string {
  return v < 10 ? '0' + v.toString() : v.toString();
}

function sessionTimestamp(): string {
  const d: Date = new Date();
  return d.getFullYear().toString() + pad2(d.getMonth() + 1) + pad2(d.getDate()) + '_' +
    pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds());
}

let sdkBootstrap: Promise<void> = Promise.resolve();

export function waitForSdkBootstrap(): Promise<void> {
  return sdkBootstrap;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setColorMode unsupported on this device');
    }
    this.requestBlePermission();
    sdkBootstrap = this.bootstrap();
    sdkBootstrap.catch((err: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'SDK bootstrap failed: %{public}s', err.message);
    });
  }

  private async setBootstrapParam(controller: SensorController, key: string, value: string): Promise<void> {
    await controller.setParam(key, value);
  }

  private async bootstrap(): Promise<void> {
    const controller: SensorController = SensorController.getInstance();
    const sessionDir: string = this.context.filesDir + '/sensorsdklog/' + sessionTimestamp() + '_' +
      controller.getVersion().replace(/\./g, '_');
    hilog.info(DOMAIN, TAG, 'LOG_PATH: %{public}s', sessionDir);
    await this.setBootstrapParam(controller, 'LOG_PATH', sessionDir);
    await this.setBootstrapParam(controller, 'DEBUG_ENABLED', 'True');
    await this.setBootstrapParam(controller, 'TRANSLATE_IMU', 'False');
    await this.setBootstrapParam(controller, 'BLE_TRACE_ENABLED', 'True');
    setBridge(this.context.filesDir);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err): void => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  onDestroy(): void {
    SensorController.terminate();
  }

  onBackground(): void {
    SensorController.getInstance().onSuspend();
  }

  private requestBlePermission(): void {
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const permissions: Array<Permissions> = ['ohos.permission.ACCESS_BLUETOOTH'];
    atManager.requestPermissionsFromUser(this.context, permissions)
      .then((): void => {
        hilog.info(DOMAIN, TAG, 'ACCESS_BLUETOOTH granted');
      })
      .catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'ACCESS_BLUETOOTH request failed: %{public}s', err.message);
      });
  }
}
