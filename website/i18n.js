"use strict";

window.AnotherYouI18n = (() => {
  const languages = [
    ["zh-Hans", "简体中文"], ["zh-Hant", "繁體中文"], ["en", "English"],
    ["ja", "日本語"], ["ko", "한국어"], ["fr", "Français"], ["de", "Deutsch"],
    ["es", "Español"], ["pt-BR", "Português (Brasil)"], ["it", "Italiano"],
    ["nl", "Nederlands"], ["ru", "Русский"], ["ar", "العربية"], ["th", "ไทย"],
    ["id", "Bahasa Indonesia"], ["vi", "Tiếng Việt"], ["tr", "Türkçe"],
  ];
  const storageKey = "another-you.website-language";

  function resolve(value) {
    if (typeof value !== "string") return null;
    const parts = value.replaceAll("_", "-").toLowerCase().split("-");
    if (parts[0] === "zh") {
      if (parts.includes("hans")) return "zh-Hans";
      return parts.some((part) => ["hant", "tw", "hk", "mo"].includes(part)) ? "zh-Hant" : "zh-Hans";
    }
    if (parts[0] === "pt") return "pt-BR";
    return languages.find(([code]) => code === parts[0])?.[0] ?? null;
  }

  function preferred(values) {
    return Array.from(values ?? []).map(resolve).find(Boolean) ?? "en";
  }

  function initialLanguage(storage, preferences) {
    try {
      const saved = resolve(storage?.getItem(storageKey));
      if (saved) return saved;
    } catch { /* 浏览器禁用存储时仍可切换语言。 */ }
    return preferred(preferences);
  }

  function saveLanguage(storage, language) {
    try { storage?.setItem(storageKey, language); } catch { /* 仅影响下次打开时的语言。 */ }
  }

  function text(language, key) {
    const value = window.AnotherYouLocales[language]?.[key];
    if (typeof value !== "string") throw new Error(`Missing translation: ${language} / ${key}`);
    return value;
  }

  function apply(language, document) {
    document.documentElement.lang = language;
    document.documentElement.dir = language === "ar" ? "rtl" : "ltr";
    for (const element of document.querySelectorAll("[data-i18n]")) {
      element.textContent = text(language, element.dataset.i18n);
    }
    for (const element of document.querySelectorAll("[data-i18n-aria]")) {
      element.setAttribute("aria-label", text(language, element.dataset.i18nAria));
    }
    for (const element of document.querySelectorAll("[data-i18n-content]")) {
      element.setAttribute("content", text(language, element.dataset.i18nContent));
    }
  }

  return { languages, storageKey, resolve, preferred, initialLanguage, saveLanguage, text, apply };
})();
