export type ThreadSearchPaletteRuleContract = {
  selectors: readonly string[];
  declarations: Readonly<Record<string, string>>;
  forbiddenProperties?: readonly string[];
};

export const THREAD_SEARCH_PALETTE_STYLE_CONTRACT = {
  tokenOwner: "styles/menus.css",
  recipeOwner: "styles/dialogs.css",
  tokenPrefix: "--palette-",
  selectorPrefix: ".thread-search-",
  tokens: {
    "--palette-surface-radius": "20px",
    "--palette-surface-shadow":
      "0 16px 32px -8px rgba(0, 0, 0, 0.19)",
    "--palette-surface-padding": "4px",
    "--palette-row-font-size": "var(--text-md)",
    "--palette-row-line-height": "21px",
    "--palette-row-idle-opacity": "0.75",
  },
  rules: [
    {
      selectors: [".thread-search-dialog[data-slot=\"dialog-content\"]"],
      declarations: {
        "--palette-list-max-height":
          "min(440px, max(120px, calc(90dvh - 64px)))",
        "--palette-max-height":
          "calc(var(--palette-list-max-height) + 64px)",
        top: "max(16px, calc((100dvh - var(--palette-max-height)) / 2))",
        display: "flex",
        "flex-direction": "column",
        gap: "var(--palette-surface-padding)",
        width: "min(520px, calc(100dvw - 48px))",
        "max-width": "min(520px, calc(100dvw - 48px))",
        height: "auto",
        "min-height": "0",
        "max-height": "var(--palette-max-height)",
        padding: "var(--palette-surface-padding)",
        overflow: "hidden",
        border: "1px solid transparent",
        "border-radius": "var(--palette-surface-radius)",
        background: "var(--color-token-bg-primary)",
        "box-shadow": "var(--palette-surface-shadow)",
        transform: "none",
      },
      forbiddenProperties: [
        "--thread-search-dialog-height",
        "grid-template-rows",
        "backdrop-filter",
        "-webkit-backdrop-filter",
      ],
    },
    {
      selectors: [".thread-search-input-shell"],
      declarations: {
        display: "block",
        padding: "0",
        "border-bottom": "0",
      },
      forbiddenProperties: ["grid-template-columns"],
    },
    {
      selectors: [".thread-search-input[data-slot=\"input\"]"],
      declarations: {
        height: "33px",
        padding: "6px 10px",
        border: "0",
        background: "transparent",
        "box-shadow": "none",
        "font-size": "var(--palette-row-font-size)",
        "font-weight": "445",
        "line-height": "var(--palette-row-line-height)",
      },
    },
    {
      selectors: [".thread-search-state"],
      declarations: {
        display: "flex",
        "align-items": "center",
        "justify-content": "center",
        gap: "8px",
        "min-height": "32px",
        padding: "var(--menu-item-padding-y) var(--menu-item-padding-x)",
        "font-size": "var(--palette-row-font-size)",
        "line-height": "1.4",
      },
      forbiddenProperties: ["flex-direction", "height"],
    },
    {
      selectors: [".thread-search-results"],
      declarations: {
        "max-height": "var(--palette-list-max-height)",
        "min-height": "0",
        padding: "0",
        "overflow-x": "hidden",
        "overflow-y": "auto",
        "overscroll-behavior": "contain",
      },
      forbiddenProperties: ["height"],
    },
    {
      selectors: [".thread-search-result-row"],
      declarations: {
        display: "flex",
        "align-items": "center",
        gap: "8px",
        width: "100%",
        "min-height": "24px",
        padding: "var(--menu-item-padding-y) var(--menu-item-padding-x)",
        border: "0",
        "border-radius": "var(--menu-item-radius)",
        background: "transparent",
        opacity: "var(--palette-row-idle-opacity)",
        "font-size": "var(--palette-row-font-size)",
        "line-height": "var(--palette-row-line-height)",
      },
      forbiddenProperties: ["grid-template-columns"],
    },
    {
      selectors: [
        ".thread-search-result-row:hover",
        ".thread-search-result-row.highlighted",
      ],
      declarations: {
        background: "var(--menu-item-hover-bg)",
        opacity: "1",
      },
    },
    {
      selectors: [".thread-search-result-avatar"],
      declarations: {
        width: "20px",
        height: "20px",
        "font-size": "9px",
      },
    },
    {
      selectors: [".thread-search-result-title"],
      declarations: {
        flex: "1 1 auto",
        overflow: "hidden",
        "min-width": "0",
        "font-size": "var(--palette-row-font-size)",
        "font-weight": "445",
        "line-height": "var(--palette-row-line-height)",
        "text-overflow": "ellipsis",
        "white-space": "nowrap",
      },
    },
    {
      selectors: [".thread-search-result-meta"],
      declarations: {
        flex: "0 0 auto",
        overflow: "hidden",
        "max-width": "180px",
        "font-size": "var(--text-base)",
        "text-align": "right",
        "text-overflow": "ellipsis",
        "white-space": "nowrap",
      },
    },
    {
      selectors: [".thread-search-result-time"],
      declarations: {
        flex: "0 0 auto",
        "font-size": "var(--text-base)",
        "text-align": "right",
      },
    },
    {
      selectors: [".thread-search-results-footer"],
      declarations: {
        "min-height": "31px",
        padding: "var(--menu-item-padding-y) var(--menu-item-padding-x)",
        "font-size": "var(--text-base)",
      },
    },
  ] satisfies readonly ThreadSearchPaletteRuleContract[],
} as const;
