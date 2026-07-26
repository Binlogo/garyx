import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import postcss from "postcss";

import { THREAD_SEARCH_PALETTE_STYLE_CONTRACT } from "./thread-search-palette-contract.ts";

const rendererDir = path.dirname(fileURLToPath(import.meta.url));
const stylesDir = path.join(rendererDir, "styles");

function readStylesheet(relativePath) {
  const absolutePath = path.join(rendererDir, relativePath);
  return postcss.parse(readFileSync(absolutePath, "utf8"), {
    from: absolutePath,
  });
}

function normalized(value) {
  return value.trim().split(/\s+/).join(" ");
}

function selectorsFor(rule) {
  return rule.selectors.map((selector) => normalized(selector));
}

function sameSelectors(actual, expected) {
  return (
    actual.length === expected.length &&
    expected.every((selector) => actual.includes(selector))
  );
}

function declarationsFor(rule) {
  const declarations = new Map();
  rule.each((node) => {
    if (node.type === "decl") {
      declarations.set(node.prop, normalized(node.value));
    }
  });
  return declarations;
}

test("thread search palette tokens have one shared menu owner", () => {
  const occurrences = new Map();
  for (const file of readdirSync(stylesDir).filter((name) =>
    name.endsWith(".css"),
  )) {
    const relativePath = `styles/${file}`;
    const root = readStylesheet(relativePath);
    root.walkDecls((declaration) => {
      if (!declaration.prop.startsWith(
        THREAD_SEARCH_PALETTE_STYLE_CONTRACT.tokenPrefix,
      )) {
        return;
      }
      const existing = occurrences.get(declaration.prop) ?? [];
      existing.push({
        owner: relativePath,
        value: normalized(declaration.value),
      });
      occurrences.set(declaration.prop, existing);
    });
  }

  const expectedTokens = Object.entries(
    THREAD_SEARCH_PALETTE_STYLE_CONTRACT.tokens,
  );
  const recipeTokens = new Map();
  for (const rule of THREAD_SEARCH_PALETTE_STYLE_CONTRACT.rules) {
    for (const [property, value] of Object.entries(rule.declarations)) {
      if (
        property.startsWith(
          THREAD_SEARCH_PALETTE_STYLE_CONTRACT.tokenPrefix,
        ) &&
        !Object.hasOwn(
          THREAD_SEARCH_PALETTE_STYLE_CONTRACT.tokens,
          property,
        )
      ) {
        recipeTokens.set(property, value);
      }
    }
  }
  assert.deepEqual(
    [...occurrences.keys()].sort(),
    [
      ...expectedTokens.map(([property]) => property),
      ...recipeTokens.keys(),
    ].sort(),
    "the reviewed --palette-* token set must not drift",
  );
  for (const [property, value] of expectedTokens) {
    assert.deepEqual(occurrences.get(property), [
      {
        owner: THREAD_SEARCH_PALETTE_STYLE_CONTRACT.tokenOwner,
        value: normalized(value),
      },
    ]);
  }
  for (const [property, value] of recipeTokens) {
    assert.deepEqual(occurrences.get(property), [
      {
        owner: THREAD_SEARCH_PALETTE_STYLE_CONTRACT.recipeOwner,
        value: normalized(value),
      },
    ]);
  }
});

test("thread search palette recipe stays in dialogs.css", () => {
  const escapedSelectors = [];
  for (const file of readdirSync(stylesDir).filter((name) =>
    name.endsWith(".css"),
  )) {
    const relativePath = `styles/${file}`;
    const root = readStylesheet(relativePath);
    root.walkRules((rule) => {
      for (const selector of selectorsFor(rule)) {
        if (
          selector.startsWith(
            THREAD_SEARCH_PALETTE_STYLE_CONTRACT.selectorPrefix,
          ) &&
          relativePath !== THREAD_SEARCH_PALETTE_STYLE_CONTRACT.recipeOwner
        ) {
          escapedSelectors.push({ owner: relativePath, selector });
        }
      }
    });
  }
  assert.deepEqual(escapedSelectors, []);

  const root = readStylesheet(
    THREAD_SEARCH_PALETTE_STYLE_CONTRACT.recipeOwner,
  );
  for (const contractRule of THREAD_SEARCH_PALETTE_STYLE_CONTRACT.rules) {
    const expectedSelectors = contractRule.selectors.map(normalized);
    const matches = [];
    root.walkRules((rule) => {
      if (sameSelectors(selectorsFor(rule), expectedSelectors)) {
        matches.push(rule);
      }
    });
    assert.equal(
      matches.length,
      1,
      `${expectedSelectors.join(", ")} must have one recipe rule`,
    );
    const declarations = declarationsFor(matches[0]);
    for (const [property, value] of Object.entries(
      contractRule.declarations,
    )) {
      assert.equal(
        declarations.get(property),
        normalized(value),
        `${expectedSelectors.join(", ")} must declare ${property}: ${value}`,
      );
    }
    for (const property of contractRule.forbiddenProperties ?? []) {
      assert.equal(
        declarations.has(property),
        false,
        `${expectedSelectors.join(", ")} must not redeclare ${property}`,
      );
    }
  }
});

test("shared tokens load before the palette owner", () => {
  const root = readStylesheet("styles.css");
  const imports = [];
  root.walkAtRules("import", (atRule) => {
    const parameter = atRule.params.trim();
    const quote = parameter[0];
    imports.push(
      quote === "\"" || quote === "'"
        ? parameter.slice(1, parameter.lastIndexOf(quote))
        : parameter,
    );
  });

  const menuImport = `./${THREAD_SEARCH_PALETTE_STYLE_CONTRACT.tokenOwner}`;
  const recipeImport =
    `./${THREAD_SEARCH_PALETTE_STYLE_CONTRACT.recipeOwner}`;
  assert.ok(imports.includes(menuImport), `${menuImport} must stay imported`);
  assert.ok(
    imports.includes(recipeImport),
    `${recipeImport} must stay imported`,
  );
  assert.ok(
    imports.indexOf(menuImport) < imports.indexOf(recipeImport),
    "palette tokens must load before the dialog recipe",
  );
});
