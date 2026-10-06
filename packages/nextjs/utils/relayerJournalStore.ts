import fs from "node:fs";
import type { Entry } from "./relayerJournal";

/**
 * Append-only JSON-lines store for the relayer journal. Each append is written and fsynced before it returns, so the
 * intent is durable before the first network call (rule 1). Replay tolerates a torn last line. One process owns the file
 * (the relayer is a single instance by design: its send queue is process-local).
 */
export class FileStore {
  readonly path: string;

  constructor(path: string) {
    this.path = path;
  }

  /** The file's lines, oldest first; an absent file is an empty journal. */
  readLines(): string[] {
    try {
      return fs.readFileSync(this.path, "utf8").split("\n").filter(l => l.length > 0);
    } catch (e: any) {
      if (e?.code === "ENOENT") return [];
      throw e;
    }
  }

  append(entry: Entry): void {
    const fd = fs.openSync(this.path, "a", 0o600);
    try {
      fs.writeSync(fd, JSON.stringify(entry) + "\n");
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
  }
}
