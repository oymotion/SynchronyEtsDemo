import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export interface LogEntry {
  name: string;
  path: string;
  isDir: boolean;
  size: number;
}

@Component
export struct LogBrowser {
  rootDir: string = '';
  rootLabel: string = 'files';
  onAppLog: (msg: string) => void = (msg: string): void => {
  };
  onReplayBin: (path: string) => void = (path: string): void => {
  };
  @State relPath: string = '';
  @State entries: LogEntry[] = [];
  @State busy: boolean = false;
  @State message: string = '';

  aboutToAppear(): void {
    try {
      if (!fs.accessSync(this.rootDir)) {
        fs.mkdirSync(this.rootDir, true);
      }
    } catch (err) {
    }
    this.refresh();
  }

  private currentDir(): string {
    return this.relPath.length === 0 ? this.rootDir : this.rootDir + '/' + this.relPath;
  }

  private breadcrumb(): string {
    return this.rootLabel + '/' + this.relPath;
  }

  private refresh(): void {
    const dir: string = this.currentDir();
    const dirs: LogEntry[] = [];
    const files: LogEntry[] = [];
    try {
      if (fs.accessSync(dir)) {
        const names: string[] = fs.listFileSync(dir);
        names.forEach((name: string): void => {
          const p: string = dir + '/' + name;
          try {
            const st: fs.Stat = fs.statSync(p);
            const entry: LogEntry = { name: name, path: p, isDir: st.isDirectory(), size: st.size };
            if (entry.isDir) {
              dirs.push(entry);
            } else {
              files.push(entry);
            }
          } catch (err) {
          }
        });
      }
    } catch (err) {
      this.message = 'Cannot read: ' + dir;
    }
    dirs.sort((a: LogEntry, b: LogEntry): number => b.name.localeCompare(a.name));
    files.sort((a: LogEntry, b: LogEntry): number => a.name.localeCompare(b.name));
    this.entries = dirs.concat(files);
  }

  private navInto(entry: LogEntry): void {
    this.relPath = this.relPath.length === 0 ? entry.name : this.relPath + '/' + entry.name;
    this.refresh();
  }

  private navUp(): void {
    const idx: number = this.relPath.lastIndexOf('/');
    this.relPath = idx < 0 ? '' : this.relPath.substring(0, idx);
    this.refresh();
  }

  private sizeText(size: number): string {
    if (size >= 1024 * 1024) {
      return (size / 1024 / 1024).toFixed(1) + ' MB';
    }
    if (size >= 1024) {
      return (size / 1024).toFixed(1) + ' KB';
    }
    return size.toString() + ' B';
  }

  // ---- export ----

  private async savePicker(defaultName: string): Promise<string[]> {
    const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    opts.newFileNames = [defaultName];
    const viewPicker: picker.DocumentViewPicker =
      new picker.DocumentViewPicker(getContext(this) as common.UIAbilityContext);
    try {
      const uris: string[] = await viewPicker.save(opts);
      return uris === null ? [] : uris;
    } catch (err) {
      return [];
    }
  }

  private async copyToUri(srcPath: string, uri: string): Promise<void> {
    const src: fs.File = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
    try {
      const dst: fs.File = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const buf: ArrayBuffer = new ArrayBuffer(4 * 1024 * 1024);
        for (;;) {
          const readLen: number = fs.readSync(src.fd, buf);
          if (readLen <= 0) {
            break;
          }
          fs.writeSync(dst.fd, buf, { length: readLen });
        }
      } finally {
        fs.closeSync(dst);
      }
    } finally {
      fs.closeSync(src);
    }
  }

  private async exportFile(entry: LogEntry): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const uris: string[] = await this.savePicker(entry.name);
      if (uris.length === 0) {
        this.message = 'Export canceled';
      } else {
        await this.copyToUri(entry.path, uris[0]);
        this.message = 'Exported: ' + entry.name;
        this.onAppLog('User: export log file ' + entry.name);
      }
    } catch (err) {
      this.message = 'Export failed: ' + entry.name;
    }
    this.busy = false;
  }

  private async exportDir(entry: LogEntry): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.message = 'Packing ' + entry.name + ' ...';
    const zipPath: string = getContext(this).cacheDir + '/' + entry.name + '.zip';
    try {
      await zlib.compressFiles([entry.path], zipPath,
        { level: zlib.CompressLevel.COMPRESS_LEVEL_BEST_SPEED });
      const uris: string[] = await this.savePicker(entry.name + '.zip');
      if (uris.length === 0) {
        this.message = 'Export canceled';
      } else {
        await this.copyToUri(zipPath, uris[0]);
        this.message = 'Exported: ' + entry.name + '.zip';
        this.onAppLog('User: export log dir ' + entry.name);
      }
    } catch (err) {
      this.message = 'Export failed: ' + entry.name;
    }
    try {
      if (fs.accessSync(zipPath)) {
        fs.unlinkSync(zipPath);
      }
    } catch (err) {
    }
    this.busy = false;
  }

  build(): void {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Button('Back')
          .fontSize(13)
          .enabled(this.relPath.length > 0)
          .onClick((): void => {
            this.navUp();
          })
        Text(this.breadcrumb())
          .fontSize(13)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      List({ space: 2 }) {
        ForEach(this.entries, (entry: LogEntry) => {
          ListItem() {
            Row({ space: 8 }) {
              Text((entry.isDir ? '[DIR] ' : '') + entry.name)
                .fontSize(13)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick((): void => {
                  if (entry.isDir) {
                    this.navInto(entry);
                  }
                })
              if (!entry.isDir) {
                Text(this.sizeText(entry.size))
                  .fontSize(12)
                  .fontColor('#666666')
              }
              if (!entry.isDir && entry.name.toLowerCase().endsWith('.bin')) {
                Button('Replay')
                  .fontSize(12)
                  .enabled(!this.busy)
                  .onClick((): void => {
                    this.onReplayBin(entry.path);
                  })
              }
              Button('Export')
                .fontSize(12)
                .enabled(!this.busy)
                .onClick((): void => {
                  if (entry.isDir) {
                    this.exportDir(entry);
                  } else {
                    this.exportFile(entry);
                  }
                })
            }
            .width('100%')
            .padding(4)
          }
        }, (entry: LogEntry) => entry.path)
      }
      .layoutWeight(1)
      .width('100%')

      if (this.entries.length === 0) {
        Text('Empty folder')
          .fontSize(13)
      }
      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(12)
          .fontColor('#333333')
          .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }
}
