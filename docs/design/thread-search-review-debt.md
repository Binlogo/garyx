# Thread Search Review Debt

## Baseline i18n literal failure

- Source: `desktop/garyx-desktop/src/renderer/src/message-rich-text-linebreaks.test.mjs:71`
  and `:75`.
- Found while running `npm run test:i18n-literals` for the Mac thread-search
  implementation.
- The unchanged baseline at commit `844b332f7` contains Han text in a Markdown
  rendering fixture, so the repository-wide scanner fails before evaluating
  the thread-search diff.
- This fixture/scanner contract is outside the thread-search implementation
  path. Resolve it in a separate task; it is not a thread-search FAIL/BLOCKER.
