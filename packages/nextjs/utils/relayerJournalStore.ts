import fs from "node:fs";
import type { Entry } from "./relayerJournal";

/** One process owns this append-only, fsynced journal, as it owns the relayer send queue. */
export class FileStore {
  readonly path: string;

  constructor(path: string) {
    this.path = path;
  }

  /** Preserve line endings so replay can distinguish corruption from an unterminated crash tail. */
  readLines(): string[] {
    try {
      return fs.readFileSync(this.path, "utf8").match(/[^\n]*\n|[^\n]+$/g) ?? [];
    } catch (e: any) {
      if (e?.code === "ENOENT") return [];
      throw e;
    }
  }

  append(entry: Entry): void {
    const fd = fs.openSync(this.path, "a+", 0o600);
    try {
      const size = fs.fstatSync(fd).size;
      if (size > 0) {
        const last = Buffer.alloc(1);
        fs.readSync(fd, last, 0, 1, size - 1);
        if (last[0] !== 10) {
          // A crash may leave an unfinished last record. Never glue the next valid entry to it:
          // replay would then lose the newly journaled hash and could misclassify a sent intent.
          const bytes = fs.readFileSync(fd);
          const boundary = bytes.lastIndexOf(10) + 1;
          let complete = false;
          try {
            JSON.parse(bytes.subarray(boundary).toString("utf8"));
            complete = true;
          } catch {
            // Only a parse error permits discarding this tail. An I/O error must preserve valid prior bytes.
          }
          if (complete) fs.writeSync(fd, "\n"); // complete JSON, only its final newline was torn
          else fs.ftruncateSync(fd, boundary); // discard only the incomplete tail
        }
      }
      fs.writeFileSync(fd, JSON.stringify(entry) + "\n");
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
  }
}
