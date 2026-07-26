import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import path from 'node:path';
import test from 'node:test';

import esbuild from 'esbuild';

const bundled = await esbuild.build({
  stdin: {
    contents: [
      'export { recentSessionWorkspaceLabel } from "./src/renderer/src/NewThreadEmptyState.tsx";',
      'export { threadSearchRowMeta } from "./src/renderer/src/app-shell/thread-search-model.ts";',
      'export { getWorkspaceLabel } from "./src/renderer/src/components/AutomationListPage.tsx";',
      'export { workspaceChipLabel } from "./src/renderer/src/components/WorkspaceComposerChip.tsx";',
      'export { workspacePathPickerLabel } from "./src/renderer/src/components/WorkspacePathPicker.tsx";',
      'export { createTranslator } from "./src/renderer/src/i18n/index.tsx";',
      'export { workspaceSuggestionFromPath } from "./src/renderer/src/thread-model.ts";',
    ].join('\n'),
    resolveDir: process.cwd(),
    sourcefile: 'workspace-leaf-callers.mjs',
  },
  alias: {
    '@': path.resolve('src/renderer/src'),
    '@renderer': path.resolve('src/renderer/src'),
    '@shared': path.resolve('src/shared'),
  },
  banner: {
    js: [
      'import { createRequire } from "node:module";',
      'const require = createRequire(process.cwd() + "/package.json");',
    ].join('\n'),
  },
  bundle: true,
  format: 'esm',
  jsx: 'automatic',
  platform: 'node',
  write: false,
});

const callers = await import(
  `data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString('base64')}`
);
const {
  createTranslator,
  getWorkspaceLabel,
  recentSessionWorkspaceLabel,
  threadSearchRowMeta,
  workspaceChipLabel,
  workspacePathPickerLabel,
  workspaceSuggestionFromPath,
} = callers;
const tZh = createTranslator('zh-CN');
const ZH_NO_WORKSPACE = '\u4e0d\u4f7f\u7528\u5de5\u4f5c\u533a';
const ZH_WORKSPACE = '\u5de5\u4f5c\u533a';
const ZH_WORKSPACE_NOT_SET = '\u672a\u8bbe\u7f6e\u5de5\u4f5c\u533a';

test('thread search rows render a leaf and the translated empty fallback', () => {
  const real = threadSearchRowMeta(
    {
      workspacePath: '/Users/test/projects/garyx',
      rootWorkspacePath: null,
      workspaceOrigin: 'explicit',
    },
    'Gary',
    tZh('No workspace'),
  );
  const empty = threadSearchRowMeta(
    {
      workspacePath: '',
      rootWorkspacePath: null,
      workspaceOrigin: 'explicit',
    },
    'Gary',
    tZh('No workspace'),
  );

  assert.equal(real.text, 'Gary · garyx');
  assert.equal(real.tooltip, 'Gary · /Users/test/projects/garyx');
  assert.equal(empty.text, `Gary · ${ZH_NO_WORKSPACE}`);
  assert.equal(empty.tooltip, `Gary · ${ZH_NO_WORKSPACE}`);
});

test('workspace suggestions keep a non-empty translated name for name consumers', () => {
  const real = workspaceSuggestionFromPath(
    '/Users/test/projects/garyx',
    tZh('Workspace'),
  );
  const emptyLeaf = workspaceSuggestionFromPath('/', tZh('Workspace'));

  assert.equal(real?.name, 'garyx');
  assert.equal(emptyLeaf?.name, ZH_WORKSPACE);
  assert.equal(workspaceSuggestionFromPath('', tZh('Workspace')), null);
});

test('recent-session rows render a leaf and the translated empty fallback', () => {
  assert.equal(
    recentSessionWorkspaceLabel('/Users/test/projects/garyx', tZh),
    'garyx',
  );
  assert.equal(recentSessionWorkspaceLabel('', tZh), ZH_NO_WORKSPACE);
});

test('workspace path picker labels preserve their empty fallback', () => {
  assert.equal(workspacePathPickerLabel('/Users/test/projects/garyx'), 'garyx');
  assert.equal(workspacePathPickerLabel(''), '');
});

test('automation rows render a leaf and their existing translated fallback', () => {
  assert.equal(
    getWorkspaceLabel(
      null,
      { workspacePath: '/Users/test/projects/garyx' },
      tZh,
    ),
    'garyx',
  );
  assert.equal(
    getWorkspaceLabel(null, { workspacePath: '' }, tZh),
    ZH_WORKSPACE_NOT_SET,
  );
});

test('composer chips preserve leaf, empty, and gateway-home labels', () => {
  assert.equal(
    workspaceChipLabel('/Users/test/projects/garyx', '/Users/test'),
    'garyx',
  );
  assert.equal(workspaceChipLabel('', '/Users/test'), '');
  assert.equal(workspaceChipLabel('/Users/test', '/Users/test/'), '~');
});

test('root workspaces preserve every caller’s pre-refactor visible label', () => {
  const searchMeta = threadSearchRowMeta(
    {
      workspacePath: '/',
      rootWorkspacePath: null,
      workspaceOrigin: 'explicit',
    },
    'Gary',
    tZh('No workspace'),
  );

  assert.equal(searchMeta.text, 'Gary · /');
  assert.equal(searchMeta.tooltip, 'Gary · /');
  assert.equal(
    workspaceSuggestionFromPath('/', tZh('Workspace'))?.name,
    ZH_WORKSPACE,
  );
  assert.equal(recentSessionWorkspaceLabel('/', tZh), '/');
  assert.equal(workspacePathPickerLabel('/'), '/');
  assert.equal(getWorkspaceLabel(null, { workspacePath: '/' }, tZh), '/');
  assert.equal(workspaceChipLabel('/', null), '/');
});

test('thread search never says no workspace while its tooltip shows a path', () => {
  const workspacePaths = [
    '/Users/test/projects/garyx',
    '/',
    '///',
    '  /  ',
    '\\\\\\',
    'garyx',
    '',
    '   ',
    null,
    undefined,
  ];

  for (const workspacePath of workspacePaths) {
    const meta = threadSearchRowMeta(
      {
        workspacePath,
        rootWorkspacePath: null,
        workspaceOrigin: 'explicit',
      },
      'Gary',
      tZh('No workspace'),
    );
    const visibleSaysNoWorkspace = meta.text === `Gary · ${ZH_NO_WORKSPACE}`;
    const tooltipSaysNoWorkspace = meta.tooltip === `Gary · ${ZH_NO_WORKSPACE}`;

    assert.equal(
      visibleSaysNoWorkspace,
      tooltipSaysNoWorkspace,
      `text/tooltip workspace state for ${JSON.stringify(workspacePath)}`,
    );
  }
});
