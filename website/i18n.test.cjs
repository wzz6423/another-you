const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const read = (name) => fs.readFileSync(path.join(__dirname, name), "utf8");

function page({ preferences = ["en"], saved, blockedStorage = false, blockedClipboard = false } = {}) {
  class Element {
    constructor() {
      this.dataset = {}; this.attributes = {}; this.listeners = {}; this.children = [];
      this.textContent = ""; this.hidden = false;
    }
    setAttribute(key, value) { this.attributes[key] = value; }
    addEventListener(name, handler) { this.listeners[name] = handler; }
    append(value) { this.children.push(value); }
    replaceChildren() { this.children = []; }
    focus() { document.activeElement = this; }
    fire(name, event = {}) { return this.listeners[name]?.(event); }
  }
  const elements = new Map();
  const translated = [];
  const html = read("index.html");
  for (const [, id] of html.matchAll(/id="([^"]+)"/g)) elements.set(id, new Element());
  const tabs = ["morning", "focus", "idle"].map((id) => {
    const element = elements.get(`tab-${id}`); element.dataset.scenario = id; return element;
  });
  for (const [, type = "", key] of html.matchAll(/data-i18n(-aria|-content)?="([^"]+)"/g)) {
    const element = new Element();
    element.dataset[type === "-aria" ? "i18nAria" : type === "-content" ? "i18nContent" : "i18n"] = key;
    translated.push(element);
  }
  const document = {
    documentElement: {}, activeElement: null,
    getElementById: (id) => assert.ok(elements.has(id), id) || elements.get(id),
    createElement: () => new Element(),
    createRange: () => ({ selectNodeContents(element) { document.selected = element; } }),
    querySelectorAll: (selector) => selector === "[data-scenario]" ? tabs : translated.filter((element) => {
      const key = { "[data-i18n]": "i18n", "[data-i18n-aria]": "i18nAria", "[data-i18n-content]": "i18nContent" }[selector];
      return key in element.dataset;
    }),
  };
  const storage = new Map(saved ? [["another-you.website-language", saved]] : []);
  const window = {
    get localStorage() {
      if (blockedStorage) throw new Error("Storage disabled");
      return { getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value) };
    },
    getSelection: () => ({ removeAllRanges() {}, addRange() {} }),
  };
  const navigator = { languages: preferences, clipboard: { async writeText(text) {
    if (blockedClipboard) throw new Error("Clipboard disabled");
    document.copied = text;
  } } };
  elements.get("start-command").textContent = "git clone example\nmake run";
  const context = vm.createContext({ window, document, navigator });
  for (const file of ["locales.js", "i18n.js", "script.js"]) vm.runInContext(read(file), context, { filename: file });
  return { window, document, elements, tabs, storage, translated };
}

test("all 17 dictionaries cover every static and interactive key with translated content", () => {
  const { window } = page();
  const base = Object.keys(window.AnotherYouLocales.en).sort();
  assert.equal(window.AnotherYouI18n.languages.length, 17);
  for (const [code] of window.AnotherYouI18n.languages) {
    const dictionary = window.AnotherYouLocales[code];
    assert.deepEqual(Object.keys(dictionary).sort(), base, code);
    for (const [key, value] of Object.entries(dictionary)) {
      assert.equal(typeof value, "string");
      assert.ok(value.trim(), `${code}: ${key}`);
      assert.doesNotMatch(value, /TODO|TRANSLATE|PLACEHOLDER/);
      if (!["zh-Hans", "zh-Hant", "ja"].includes(code)) assert.doesNotMatch(value, /[\u4e00-\u9fff]/, `${code}: ${key}`);
    }
    const site = page({ preferences: [code] });
    for (const tab of site.tabs) {
      tab.fire("click");
      for (const decision of ["accept", "snooze", "dismiss"]) {
        site.elements.get(`${decision}-suggestion`).fire("click");
        assert.ok(site.elements.get("outcome-title").textContent);
        if (decision === "accept") assert.equal(site.elements.get("draft-list").children.length, 3);
        site.elements.get("reset-suggestion").fire("click");
      }
    }
  }
});

test("saved language, system fallback and unavailable storage", () => {
  assert.equal(page({ preferences: ["xx", "zh_HK"] }).document.documentElement.lang, "zh-Hant");
  assert.equal(page({ preferences: ["xx"] }).document.documentElement.lang, "en");
  assert.equal(page({ preferences: ["ja"], saved: "pt-PT" }).document.documentElement.lang, "pt-BR");
  assert.equal(page({ preferences: ["ko"], saved: "invalid" }).document.documentElement.lang, "ko");
  assert.equal(page({ preferences: ["fr"], blockedStorage: true }).document.documentElement.lang, "fr");
});

test("language changes preserve decisions, translate visible outcomes and persist RTL", () => {
  const site = page();
  site.elements.get("accept-suggestion").fire("click");
  const picker = site.elements.get("language-select");
  picker.value = "ar"; picker.fire("change");
  assert.equal(site.document.documentElement.dir, "rtl");
  assert.equal(site.storage.get("another-you.website-language"), "ar");
  assert.equal(site.elements.get("outcome-view").hidden, false);
  assert.equal(site.elements.get("outcome-title").textContent, site.window.AnotherYouLocales.ar["一份小小的草稿，准备好了。"]);
  site.tabs[0].fire("keydown", { key: "ArrowLeft", preventDefault() {} });
  assert.equal(site.document.activeElement, site.tabs[1]);
  site.tabs[0].fire("click");
  assert.equal(site.elements.get("outcome-view").hidden, false);
  picker.value = "en"; picker.fire("change");
  assert.equal(site.document.documentElement.dir, "ltr");
});

test("copy success and denied clipboard show localized status for every language", async () => {
  const { window } = page();
  for (const [language] of window.AnotherYouI18n.languages) {
    for (const blockedClipboard of [false, true]) {
      const site = page({ preferences: [language], blockedClipboard });
      await site.elements.get("copy-command").fire("click");
      const key = blockedClipboard ? "浏览器未允许自动复制。命令已选中，请按 ⌘C（或 Ctrl+C）复制。" : "启动命令已复制。";
      assert.equal(site.elements.get("copy-status").textContent, site.window.AnotherYouLocales[language][key]);
      assert.equal(blockedClipboard ? site.document.selected : site.document.copied, blockedClipboard ? site.elements.get("start-command") : "git clone example\nmake run");
    }
  }
});
