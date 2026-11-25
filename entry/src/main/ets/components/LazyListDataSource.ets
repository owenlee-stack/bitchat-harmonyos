/**
 * Generic lazy list data source (T079, SC-007 60fps message stream).
 *
 * Feeds LazyForEach in the chat timeline views so long histories only
 * build the visible rows on demand instead of eagerly constructing every
 * bubble up front (ForEach builds all children at first layout). The
 * views keep their row render models and key generators; this source
 * only holds the current row array and fans out onDataReloaded to the
 * registered listeners when reload() replaces it.
 */
export class LazyListDataSource<T extends Object> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Object {
    return this.items[index];
  }

  /** Typed element access for row builders and empty checks. */
  getItem(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /**
   * Replace the whole data set; LazyForEach re-requests totalCount and
   * re-keys the visible rows (stable keys reuse the built bubbles).
   */
  reload(items: T[]): void {
    this.items = items;
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}
