/** Replaces queued work without releasing slots still held by obsolete native operations. */
export class LatestTaskPool<T> {
  private generation: number = 0;
  private active: number = 0;
  private items: T[] = [];
  private cursor: number = 0;
  private work?: (item: T, isCurrent: () => boolean) => Promise<void>;

  private readonly concurrency: number;

  constructor(concurrency: number) {
    this.concurrency = Math.max(1, concurrency);
  }

  replace(items: T[], work: (item: T, isCurrent: () => boolean) => Promise<void>): void {
    this.cancel();
    this.items = items;
    this.work = work;
    this.pump();
  }

  cancel(): void {
    this.generation++;
    this.items = [];
    this.cursor = 0;
    this.work = undefined;
  }

  private pump(): void {
    const work = this.work;
    if (work === undefined) return;
    while (this.active < Math.max(1, this.concurrency) && this.cursor < this.items.length) {
      const item: T = this.items[this.cursor++];
      const generation: number = this.generation;
      const isCurrent: () => boolean = () => generation === this.generation;
      this.active++;
      Promise.resolve().then(async (): Promise<void> => {
        if (isCurrent()) await work(item, isCurrent);
      }).catch(() => {
        // One failed cache/preview task must not stop the remaining queue.
      }).finally(() => {
        this.active--;
        this.pump();
      });
    }
    if (this.cursor >= this.items.length) {
      this.items = [];
      this.cursor = 0;
      this.work = undefined;
    }
  }
}
