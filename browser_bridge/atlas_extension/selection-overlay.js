(function () {
  const BUTTON_ID = "fuckyouxcode-selection-button";
  const HIDE_DELAY_MS = 160;

  let hideTimer = null;
  let lastSelection = "";

  function normalizeSelectionText(value) {
    if (!value) return "";
    return value.trim().replace(/^[^\w]+|[^\w]+$/g, "");
  }

  function getButton() {
    let button = document.getElementById(BUTTON_ID);
    if (button) return button;

    button = document.createElement("button");
    button.id = BUTTON_ID;
    button.type = "button";
    button.textContent = "用 FuckYouXcode 查词";
    button.style.position = "fixed";
    button.style.zIndex = "2147483647";
    button.style.display = "none";
    button.style.padding = "10px 14px";
    button.style.border = "none";
    button.style.borderRadius = "999px";
    button.style.background = "linear-gradient(135deg, #b65c2d 0%, #8f3f17 100%)";
    button.style.color = "#fff";
    button.style.fontSize = "13px";
    button.style.fontFamily = "system-ui, -apple-system, BlinkMacSystemFont, sans-serif";
    button.style.boxShadow = "0 14px 30px rgba(66, 34, 12, 0.24)";
    button.style.cursor = "pointer";

    button.addEventListener("mouseenter", () => {
      if (hideTimer) {
        clearTimeout(hideTimer);
        hideTimer = null;
      }
    });

    button.addEventListener("mouseleave", () => {
      scheduleHide();
    });

    button.addEventListener("mousedown", (event) => {
      event.preventDefault();
    });

    button.addEventListener("click", async (event) => {
      event.preventDefault();
      const text = lastSelection;
      hideButton();
      if (!text) return;

      // Store the word to extension storage first, so it's ready regardless
      // of whether the side panel opens programmatically or manually.
      try {
        if (chrome?.storage?.local) {
          const current = await chrome.storage.local.get(["selectedDictionaryId"]);
          await chrome.storage.local.set({
            lookupWord: text,
            lookupUpdatedAt: Date.now(),
            selectedDictionaryId: current.selectedDictionaryId || "builtin.default"
          });
        }
      } catch (_) {}

      try {
        await chrome.runtime.sendMessage({
          type: "lookup-selection",
          selectionText: text
        });
      } catch (_) {}
    });

    document.documentElement.appendChild(button);
    return button;
  }

  function hideButton() {
    const button = document.getElementById(BUTTON_ID);
    if (!button) return;
    button.style.display = "none";
  }

  function scheduleHide() {
    if (hideTimer) clearTimeout(hideTimer);
    hideTimer = window.setTimeout(() => {
      hideButton();
      hideTimer = null;
    }, HIDE_DELAY_MS);
  }

  function currentSelectionText() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return "";
    return normalizeSelectionText(selection.toString());
  }

  function updateButtonForSelection() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
      hideButton();
      return;
    }

    const text = normalizeSelectionText(selection.toString());
    if (!text) {
      hideButton();
      return;
    }

    const range = selection.getRangeAt(0);
    const rects = range.getClientRects();
    const rect = rects.length > 0 ? rects[rects.length - 1] : range.getBoundingClientRect();
    if (!rect) {
      hideButton();
      return;
    }

    lastSelection = text;
    const button = getButton();
    const top = Math.min(window.innerHeight - 52, Math.max(8, rect.bottom + 10));
    const left = Math.min(window.innerWidth - 220, Math.max(8, rect.left));
    button.style.top = `${top}px`;
    button.style.left = `${left}px`;
    button.style.display = "block";
  }

  document.addEventListener("mouseup", () => {
    window.setTimeout(updateButtonForSelection, 0);
  });

  document.addEventListener("keyup", () => {
    window.setTimeout(updateButtonForSelection, 0);
  });

  document.addEventListener("mousedown", (event) => {
    const button = document.getElementById(BUTTON_ID);
    if (!button) return;
    if (event.target === button) return;
    scheduleHide();
  });

  document.addEventListener("scroll", () => {
    if (document.getElementById(BUTTON_ID)?.style.display === "block") {
      scheduleHide();
    }
  }, true);
})();
