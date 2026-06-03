# FuckYouXcode

An iOS dictionary application built with SwiftUI, designed for English learners who need instant word lookup and vocabulary management. It combines a built-in SQLite-powered English-Chinese dictionary with support for importing external MDict-format dictionaries (e.g., Oxford Advanced Learner's Dictionary). Users can look up words through text search, OCR-based photo recognition, or an AI-powered chat assistant. The app offers word collections, favorites management, and multi-catalog dictionary switching. A companion Python server and browser extension extend dictionary lookup to desktop browsers via a local HTTP API and MCP (Model Context Protocol) interface.

## Architecture Overview

```mermaid
flowchart TD
    %% ===== ENTRY POINT =====
    APP["<b>FuckYouXcodeApp.swift</b><br/>@main entry point<br/>initializes state objects"]

    %% ===== STATE LAYER =====
    APP --> STATE["<b>AppState.swift</b><br/>bootstraps DBs, creates<br/>DictionaryService,<br/>manages catalogs"]
    APP --> SELECTION["<b>SelectionManager.swift</b><br/>text selection state"]
    APP --> AI_STORE["<b>AISettingsStore.swift</b><br/><b>AIChatHistoryStore.swift</b><br/>AI config & history"]

    %% ===== VIEW LAYER =====
    STATE --> CV["<b>ContentView.swift</b><br/>root TabView"]
    SELECTION --> CV

    %% ===== 3 TABS =====
    CV --> TAB_OCR["<b>SearchWordsFromVideosView</b><br/>Tab 1: OCR photo word lookup"]
    CV --> TAB_COLLECTION["<b>WordsCollectionView</b><br/>Tab 2: word collections"]
    CV --> TAB_SEARCH["<b>DictionaryRootView</b><br/>Tab 3: dictionary search"]

    %% ===== TAB 1: OCR PIPELINE =====
    TAB_OCR --> OCR_SVC["<b>OCRService.swift</b><br/>optical character recognition"]
    TAB_OCR --> EXTRACTOR["<b>WordExtractor.swift</b><br/>extract words from text"]
    TAB_OCR --> SEL_TEXT["<b>SelectableText.swift</b><br/>selectable text component"]
    TAB_OCR --> OFF_DICT["<b>OfficialDictionaryEntryView.swift</b><br/>iOS system dictionary wrapper"]

    %% ===== TAB 2: COLLECTIONS =====
    TAB_COLLECTION --> WC_DETAIL["<b>WordCollectionDetailView.swift</b><br/>single collection detail"]
    TAB_COLLECTION --> USER_SVC["<b>UserDataService.swift</b><br/>(Actor) favorites & collection CRUD"]
    USER_SVC --> USER_DB["<b>UserDB.swift</b><br/>user SQLite via GRDB"]
    USER_SVC --> SYNC["<b>UserCloudSyncService.swift</b><br/>iCloud sync (currently disabled)"]
    USER_SVC --> PATHS["<b>UserStoragePaths.swift</b><br/>app storage paths"]

    %% ===== TAB 3: DICTIONARY SEARCH =====
    TAB_SEARCH --> SEARCH_VIEW["<b>DictionarySearchView.swift</b><br/>search bar & suggestions"]
    SEARCH_VIEW --> DICT_SVC["<b>DictionaryService.swift</b><br/>core word lookup engine"]

    %% ===== DICTIONARY ENGINE =====
    DICT_SVC --> DICT_DB["<b>DictionaryDB.swift</b><br/>built-in dict SQLite via GRDB"]
    DICT_SVC --> ENTRY_VIEW["<b>DictionaryEntryView.swift</b><br/>full entry display"]

    %% ===== MDICT HTML RENDERING =====
    ENTRY_VIEW --> HTML_VIEW["<b>MDictHTMLView.swift</b><br/>WKWebView wrapper"]
    HTML_VIEW --> SCHEME["<b>MDictAssetSchemeHandler.swift</b><br/>dict:// URL handler"]
    HTML_VIEW --> BRIDGE["<b>MDictHTMLSelectionBridge.swift</b><br/>text selection JS bridge"]
    HTML_VIEW --> NORM["<b>HTMLPlainTextNormalizer.swift</b><br/>HTML-to-plaintext"]

    %% ===== DICTIONARY IMPORT =====
    STATE --> CATALOG["<b>DictionaryCatalogStore.swift</b><br/>imported dict catalog records"]
    STATE --> IMPORTER["<b>DictionaryImportIndexer.swift</b><br/>external dictionary importer"]
    IMPORTER --> MDX["<b>MDXParser.swift</b><br/>MDX format parser"]
    IMPORTER --> MDD["<b>MDDParser.swift</b><br/>MDD resource parser"]

    %% ===== AI CHAT =====
    AI_STORE --> AI_VIEWS["<b>AIChatViews.swift</b><br/>AI chat UI"]
    AI_VIEWS --> AI_CLIENT["<b>OpenAIChatClient.swift</b><br/>OpenAI API client"]
    AI_CLIENT --> AI_MODEL["<b>AIChatModels.swift</b><br/>chat message models"]

    %% ===== BROWSER BRIDGE (separate system) =====
    subgraph BRIDGE[" Browser Bridge (Python companion) "]
        direction TB
        HTTP["<b>dictionary_server.py</b><br/>Local HTTP API on :8765"]
        MCP["<b>fuckyouxcode_mcp_server.py</b><br/>MCP stdio server"]
        EXTENSION["<b>atlas_extension/</b><br/>Chromium browser extension"]
        HTTP --> EXTENSION
        MCP --> EXTENSION
    end
```
