const STORAGE_WORD_KEY = "lookupWord";
const STORAGE_UPDATED_AT_KEY = "lookupUpdatedAt";
const STORAGE_DICTIONARY_ID_KEY = "selectedDictionaryId";
const API_BASES = ["http://127.0.0.1:8765", "http://localhost:8765"];
const extensionChrome = globalThis.chrome;

const form = document.getElementById("lookup-form");
const input = document.getElementById("lookup-input");
const dictionarySelect = document.getElementById("dictionary-select");
const statusCard = document.getElementById("status-card");
const htmlPanel = document.getElementById("html-panel");
const htmlFrame = document.getElementById("html-frame");
const htmlPanelCaption = document.getElementById("html-panel-caption");
const results = document.getElementById("results");
const entryTemplate = document.getElementById("entry-template");

let activeApiBase = null;
let dictionariesLoaded = false;

function normalizeWord(value) {
  return (value || "").trim().replace(/^[^\w]+|[^\w]+$/g, "");
}

function setStatus(message, kind = "info") {
  if (!message) {
    statusCard.textContent = "";
    statusCard.className = "status-card";
    return;
  }

  statusCard.textContent = message;
  statusCard.className = `status-card visible${kind === "error" ? " error" : ""}`;
}

function sectionVisible(section, title, bodyNode) {
  section.classList.add("visible");
  section.innerHTML = "";

  const titleNode = document.createElement("h3");
  titleNode.className = "section-title";
  titleNode.textContent = title;

  section.append(titleNode, bodyNode);
}

function paragraphNode(text) {
  const node = document.createElement("p");
  node.className = "section-body";
  node.textContent = text;
  return node;
}

function originationNode(text) {
  const node = document.createElement("p");
  node.className = "section-body";

  const linkPattern = /\[\[([^\[\]\r\n]{1,80})\]\]/g;
  let cursor = 0;
  let match;

  while ((match = linkPattern.exec(text || "")) !== null) {
    if (match.index > cursor) {
      node.appendChild(document.createTextNode(text.slice(cursor, match.index)));
    }

    const word = match[1].trim();
    if (word) {
      const link = document.createElement("a");
      link.className = "inline-dict-link";
      link.href = "#";
      link.textContent = word;
      link.addEventListener("click", (event) => {
        event.preventDefault();
        void setStoredValues({
          [STORAGE_WORD_KEY]: word,
          [STORAGE_UPDATED_AT_KEY]: Date.now(),
          [STORAGE_DICTIONARY_ID_KEY]: dictionarySelect.value || "builtin.default"
        });
        void lookup(word);
      });
      node.appendChild(link);
    } else {
      node.appendChild(document.createTextNode(match[0]));
    }

    cursor = linkPattern.lastIndex;
  }

  if (cursor < (text || "").length) {
    node.appendChild(document.createTextNode(text.slice(cursor)));
  }

  return node;
}

function clearHtmlPanel() {
  htmlPanel.hidden = true;
  htmlFrame.src = "about:blank";
  htmlPanelCaption.textContent = "";
}

function showHtmlPanel(renderUrl, dictionaryDisplayName) {
  if (!renderUrl || !activeApiBase) {
    clearHtmlPanel();
    return;
  }

  htmlPanel.hidden = false;
  htmlFrame.src = `${activeApiBase}${renderUrl}`;
  htmlPanelCaption.textContent = dictionaryDisplayName || "";
}

function renderEmptyState(title, message) {
  results.innerHTML = "";
  clearHtmlPanel();
  const card = document.createElement("article");
  card.className = "empty-card";
  const heading = document.createElement("h2");
  heading.textContent = title;
  const body = document.createElement("p");
  body.textContent = message;
  card.append(heading, body);
  results.appendChild(card);
}

function renderEntries(query, payload) {
  results.innerHTML = "";
  showHtmlPanel(payload.htmlRenderUrl, payload.dictionary?.displayName);

  if (!payload.entries || payload.entries.length === 0) {
    renderEmptyState("没有查到结果", `当前没有找到 “${query}” 的词条。你也可以换一个词试试。`);
    return;
  }

  for (const entry of payload.entries) {
    const fragment = entryTemplate.content.cloneNode(true);
    fragment.querySelector(".entry-word").textContent = entry.word;

    const metaBits = [entry.phonetic, entry.pos, entry.lemma && entry.lemma !== entry.word ? `lemma: ${entry.lemma}` : ""]
      .filter(Boolean);
    fragment.querySelector(".entry-meta").textContent = metaBits.join("  ·  ");

    const badges = fragment.querySelector(".entry-badges");
    if (entry.frequency) {
      const badge = document.createElement("span");
      badge.className = "badge";
      badge.textContent = `Frequency ${entry.frequency}`;
      badges.appendChild(badge);
    }
    if (entry.level) {
      const badge = document.createElement("span");
      badge.className = "badge";
      badge.textContent = entry.level;
      badges.appendChild(badge);
    }

    if (entry.definition) {
      sectionVisible(
        fragment.querySelector(".entry-definition"),
        "Definition",
        paragraphNode(entry.definition)
      );
    }

    if (entry.idioms) {
      sectionVisible(
        fragment.querySelector(".entry-idioms"),
        "Idioms",
        paragraphNode(entry.idioms)
      );
    }

    if (entry.examples) {
      const list = document.createElement("ol");
      list.className = "example-list";
      const items = entry.examples.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
      for (const item of items) {
        const li = document.createElement("li");
        li.textContent = item;
        list.appendChild(li);
      }
      sectionVisible(fragment.querySelector(".entry-examples"), "Examples", list);
    }

    if (entry.origination) {
      sectionVisible(
        fragment.querySelector(".entry-origin"),
        "Origination",
        originationNode(entry.origination)
      );
    }

    results.appendChild(fragment);
  }
}

function optionLabelForDictionary(dictionary) {
  if (dictionary.isSelectable) return dictionary.displayName;
  if (dictionary.status === "indexing") return `${dictionary.displayName}（索引中）`;
  if (dictionary.status === "failed") return `${dictionary.displayName}（失败）`;
  return dictionary.displayName;
}

async function getStoredValues(keys) {
  if (!extensionChrome?.storage?.local) return {};
  return extensionChrome.storage.local.get(keys);
}

async function setStoredValues(payload) {
  if (!extensionChrome?.storage?.local) return;
  await extensionChrome.storage.local.set(payload);
}

async function ensureDictionaryOptionsLoaded() {
  if (dictionariesLoaded && dictionarySelect.options.length > 0) return;

  const base = await resolveApiBase();
  const data = await fetchJson(`${base}/api/dictionaries`);
  const dictionaries = Array.isArray(data.dictionaries) ? data.dictionaries : [];
  const stored = await getStoredValues([STORAGE_DICTIONARY_ID_KEY]);
  const selectable = dictionaries.filter((item) => item.isSelectable);
  let selectedId = stored[STORAGE_DICTIONARY_ID_KEY] || dictionarySelect.value || selectable[0]?.id || "builtin.default";

  if (!selectable.some((item) => item.id === selectedId)) {
    selectedId = selectable[0]?.id || "builtin.default";
  }

  dictionarySelect.innerHTML = "";
  for (const dictionary of dictionaries) {
    const option = document.createElement("option");
    option.value = dictionary.id;
    option.textContent = optionLabelForDictionary(dictionary);
    option.disabled = !dictionary.isSelectable;
    option.selected = dictionary.id === selectedId;
    dictionarySelect.appendChild(option);
  }

  if (dictionarySelect.options.length === 0) {
    const option = document.createElement("option");
    option.value = "builtin.default";
    option.textContent = "默认词典";
    dictionarySelect.appendChild(option);
  }

  dictionarySelect.value = selectedId;
  dictionariesLoaded = true;
  await setStoredValues({ [STORAGE_DICTIONARY_ID_KEY]: dictionarySelect.value });
}

async function fetchJson(url, timeoutMs = 3000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function resolveApiBase() {
  if (activeApiBase) return activeApiBase;

  for (const base of API_BASES) {
    try {
      await fetchJson(`${base}/health`, 1500);
      activeApiBase = base;
      return base;
    } catch (_) {}
  }

  throw new Error("Local dictionary bridge is not running");
}

async function lookup(word) {
  const normalized = normalizeWord(word);
  input.value = normalized;

  if (!normalized) {
    renderEmptyState("等待查词", "先在网页里右键选中一个英文单词，或者在上方直接输入。");
    setStatus("", "info");
    return;
  }

  setStatus(`正在查询 “${normalized}”…`);

  try {
    await ensureDictionaryOptionsLoaded();
    const base = await resolveApiBase();
    const dictionaryId = dictionarySelect.value || "builtin.default";
    const payload = await fetchJson(
      `${base}/api/lookup?word=${encodeURIComponent(normalized)}&dictionaryId=${encodeURIComponent(dictionaryId)}`
    );
    renderEntries(normalized, payload);
    setStatus(`已连接本地词典服务：${base} · 当前词典：${payload.dictionary?.displayName || dictionaryId}`);
  } catch (error) {
    renderEmptyState(
      "本地服务未连接",
      "请先运行 browser_bridge/dictionary_server.py，然后再重试查词。"
    );
    setStatus(String(error.message || error), "error");
  }
}

async function handleStoredWordChange() {
  if (!extensionChrome?.storage?.local) {
    const params = new URLSearchParams(location.search);
    await lookup(params.get("word") || "");
    return;
  }

  const stored = await extensionChrome.storage.local.get([STORAGE_WORD_KEY, STORAGE_DICTIONARY_ID_KEY]);
  if (stored[STORAGE_DICTIONARY_ID_KEY]) {
    dictionarySelect.value = stored[STORAGE_DICTIONARY_ID_KEY];
  }
  const params = new URLSearchParams(location.search);
  const candidate = stored[STORAGE_WORD_KEY] || params.get("word") || "";
  await lookup(candidate);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const word = normalizeWord(input.value);
  await setStoredValues({
    [STORAGE_WORD_KEY]: word,
    [STORAGE_UPDATED_AT_KEY]: Date.now(),
    [STORAGE_DICTIONARY_ID_KEY]: dictionarySelect.value || "builtin.default"
  });
  await lookup(word);
});

dictionarySelect.addEventListener("change", async () => {
  await setStoredValues({ [STORAGE_DICTIONARY_ID_KEY]: dictionarySelect.value || "builtin.default" });
  const currentWord = normalizeWord(input.value);
  if (currentWord) {
    await lookup(currentWord);
  }
});

extensionChrome?.storage?.onChanged?.addListener((changes, area) => {
  if (area !== "local") return;
  if (!changes[STORAGE_WORD_KEY] && !changes[STORAGE_UPDATED_AT_KEY]) return;
  void handleStoredWordChange();
});

void ensureDictionaryOptionsLoaded()
  .catch(() => {})
  .then(() => handleStoredWordChange());
