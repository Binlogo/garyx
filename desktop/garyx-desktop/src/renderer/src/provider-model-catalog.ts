import type {
  DesktopApiProviderType,
  DesktopProviderModels,
} from '@shared/contracts';

export type ProviderModelCatalogSnapshot = {
  catalogs: Partial<Record<DesktopApiProviderType, DesktopProviderModels>>;
  refreshing: Partial<Record<DesktopApiProviderType, boolean>>;
};

type ProviderModelCatalogLoader = (
  providerType: DesktopApiProviderType,
) => Promise<DesktopProviderModels>;

type InFlightRequest = {
  epoch: number;
  id: number;
  promise: Promise<boolean>;
};

const EMPTY_SNAPSHOT: ProviderModelCatalogSnapshot = {
  catalogs: {},
  refreshing: {},
};

/**
 * Gateway-scoped stale-while-refresh owner for every renderer consumer of
 * provider model catalogs.
 *
 * Refreshes never blank an existing snapshot, failures are deliberately silent,
 * and every provider has at most one request in flight. A gateway-scope change
 * clears the cache synchronously and fences late responses from the old epoch.
 */
export class ProviderModelCatalog {
  private readonly load: ProviderModelCatalogLoader;
  private readonly listeners = new Set<() => void>();
  private readonly inFlight = new Map<DesktopApiProviderType, InFlightRequest>();
  private gatewayScope: string | null = null;
  private epoch = 0;
  private nextRequestId = 1;
  private snapshot: ProviderModelCatalogSnapshot = EMPTY_SNAPSHOT;

  constructor(load: ProviderModelCatalogLoader) {
    this.load = load;
  }

  readonly getSnapshot = (): ProviderModelCatalogSnapshot => this.snapshot;

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  setGatewayScope(gatewayScope: string): void {
    if (this.gatewayScope === gatewayScope) {
      return;
    }
    this.gatewayScope = gatewayScope;
    this.epoch += 1;
    this.inFlight.clear();
    this.snapshot = {
      catalogs: {},
      refreshing: {},
    };
    this.emit();
  }

  refresh(providerType: DesktopApiProviderType): Promise<boolean> {
    const existing = this.inFlight.get(providerType);
    if (existing?.epoch === this.epoch) {
      return existing.promise;
    }

    const request: InFlightRequest = {
      epoch: this.epoch,
      id: this.nextRequestId,
      promise: Promise.resolve(false),
    };
    this.nextRequestId += 1;
    this.inFlight.set(providerType, request);
    request.promise = Promise.resolve().then(() =>
      this.runRefresh(providerType, request),
    );
    this.setRefreshing(providerType, true);
    return request.promise;
  }

  async refreshKnown(): Promise<void> {
    const providers = Object.keys(
      this.snapshot.catalogs,
    ) as DesktopApiProviderType[];
    await Promise.all(providers.map((providerType) => this.refresh(providerType)));
  }

  private async runRefresh(
    providerType: DesktopApiProviderType,
    request: InFlightRequest,
  ): Promise<boolean> {
    try {
      const models = await this.load(providerType);
      if (!this.isCurrent(providerType, request)) {
        return false;
      }
      this.snapshot = {
        catalogs: {
          ...this.snapshot.catalogs,
          [providerType]: models,
        },
        refreshing: {
          ...this.snapshot.refreshing,
          [providerType]: false,
        },
      };
      this.emit();
      return true;
    } catch {
      if (this.isCurrent(providerType, request)) {
        this.setRefreshing(providerType, false);
      }
      return false;
    } finally {
      if (this.isCurrent(providerType, request)) {
        this.inFlight.delete(providerType);
      }
    }
  }

  private isCurrent(
    providerType: DesktopApiProviderType,
    request: InFlightRequest,
  ): boolean {
    const current = this.inFlight.get(providerType);
    return request.epoch === this.epoch
      && current?.epoch === request.epoch
      && current.id === request.id;
  }

  private setRefreshing(
    providerType: DesktopApiProviderType,
    refreshing: boolean,
  ): void {
    this.snapshot = {
      catalogs: this.snapshot.catalogs,
      refreshing: {
        ...this.snapshot.refreshing,
        [providerType]: refreshing,
      },
    };
    this.emit();
  }

  private emit(): void {
    for (const listener of this.listeners) {
      listener();
    }
  }
}
