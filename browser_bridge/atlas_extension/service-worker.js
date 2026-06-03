const MENU_ID = "fuckyouxcode.lookup";
const LOOKUP_WORD_KEY = "lookupWord";
const LOOKUP_UPDATED_AT_KEY = "lookupUpdatedAt";
const LOOKUP_DICTIONARY_ID_KEY = "selectedDictionaryId";
const hasContextMenus = Boolean(
  chrome?.contextMenus &&
  typeof chrome.contextMenus.create === "function" &&
  chrome.contextMenus.onClicked
);
const hasAction = Boolean(chrome?.action?.onClicked);
const hasSidePanel = Boolean(chrome?.sidePanel?.open);

function normalizeSelectionText(value) {
  if (!value) return "";
  return value
    .trim()
    .replace(/^[^\w]+|[^\w]+$/g, "");
}

async function ensureContextMenu() {
  if (!hasContextMenus) return;

  try {
    await chrome.contextMenus.removeAll();
  } catch (_) {}

  chrome.contextMenus.create({
    id: MENU_ID,
    title: "用 FuckYouXcode 查词",
    contexts: ["selection"]
  });
}

/**
 * Store the selected word into extension local storage.
 * The side panel's storage.onChanged listener will pick it up automatically.
 * This is intentionally separated from side-panel opening so that
 * sidePanel.open() can be called synchronously in the gesture context.
 */
async function storeWordForLookup(selectionText) {
  const word = normalizeSelectionText(selectionText);
  if (!word) return;

  const current = await chrome.storage.local.get([LOOKUP_DICTIONARY_ID_KEY]);
  await chrome.storage.local.set({
    [LOOKUP_WORD_KEY]: word,
    [LOOKUP_UPDATED_AT_KEY]: Date.now(),
    [LOOKUP_DICTIONARY_ID_KEY]: current[LOOKUP_DICTIONARY_ID_KEY] || "builtin.default"
  });
}

/**
 * Open the side panel (or fall back to a new tab) immediately.
 *
 * IMPORTANT: This function must be called **synchronously** inside a user-gesture
 * event handler (contextMenus.onClicked, action.onClicked). Any preceding `await`
 * will break the gesture chain and cause Atlas / Chrome to reject the call.
 */
function openSidePanelForTab(tabId) {
  if (hasSidePanel && typeof tabId === "number") {
    chrome.sidePanel.open({ tabId }).catch(() => {
      // Atlas may reject the call; fall back to a new tab.
      const url = chrome.runtime.getURL("sidepanel.html");
      chrome.tabs.create({ url }).catch(() => {});
    });
  } else {
    const url = chrome.runtime.getURL("sidepanel.html");
    chrome.tabs.create({ url }).catch(() => {});
  }
}

function configurePanelBehavior() {
  // Allow opening the side panel via the toolbar extension icon click.
  if (chrome.sidePanel?.setPanelBehavior) {
    chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

chrome.runtime.onInstalled.addListener(() => {
  void ensureContextMenu();
  configurePanelBehavior();
});

chrome.runtime.onStartup?.addListener(() => {
  void ensureContextMenu();
  configurePanelBehavior();
});

// ---------------------------------------------------------------------------
// Context menu  (right-click → "用 FuckYouXcode 查词")
// ---------------------------------------------------------------------------

if (hasContextMenus) {
  chrome.contextMenus.onClicked.addListener((info, tab) => {
    if (info.menuItemId !== MENU_ID) return;

    // ★ CRITICAL: Open the side panel SYNCHRONOUSLY, before any async work.
    // This preserves the user-gesture context that Chrome/Atlas requires.
    openSidePanelForTab(tab?.id);

    // Then persist the word asynchronously; sidepanel.js will pick it up
    // via its chrome.storage.onChanged listener.
    void storeWordForLookup(info.selectionText || "");
  });
}

// ---------------------------------------------------------------------------
// Toolbar icon click (backup when setPanelBehavior is not available)
// ---------------------------------------------------------------------------

if (hasAction) {
  chrome.action.onClicked.addListener((tab) => {
    openSidePanelForTab(tab?.id);
  });
}

// ---------------------------------------------------------------------------
// Content-script message  (floating overlay button → lookup-selection)
// ---------------------------------------------------------------------------

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "lookup-selection") return false;

  const tabId = sender.tab?.id;

  // Content-script messages do NOT carry user-gesture context in the service
  // worker, so sidePanel.open() may fail here. We still try, but prepare a
  // fallback that opens the side panel page in a new tab.
  if (hasSidePanel && typeof tabId === "number") {
    chrome.sidePanel.open({ tabId }).catch(() => {
      const word = normalizeSelectionText(message.selectionText || "");
      if (word) {
        const url = chrome.runtime.getURL(`sidepanel.html?word=${encodeURIComponent(word)}`);
        chrome.tabs.create({ url }).catch(() => {});
      }
    });
  }

  void storeWordForLookup(message.selectionText || "")
    .then(() => sendResponse({ ok: true }))
    .catch((error) => {
      sendResponse({
        ok: false,
        error: String(error?.message || error)
      });
    });

  return true;
});
