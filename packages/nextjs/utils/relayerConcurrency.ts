/**
 * One in-flight operation for each signed intent. Duplicate HTTP requests share its outcome;
 * recovery must not abandon a request that is still being signed in this process.
 * This is process-local, matching the file journal and the relayer account's send queue.
 */
export class IntentFlights<T> {
  private active = new Map<string, { digest: string; promise: Promise<T> }>();

  has(key: string): boolean {
    return this.active.has(key);
  }

  run(key: string, digest: string, operation: () => Promise<T>, conflict: () => Error): Promise<T> {
    const existing = this.active.get(key);
    if (existing) return existing.digest === digest ? existing.promise : Promise.reject(conflict());
    const promise = Promise.resolve().then(operation).finally(() => {
      this.active.delete(key);
    });
    this.active.set(key, { digest, promise });
    return promise;
  }
}
