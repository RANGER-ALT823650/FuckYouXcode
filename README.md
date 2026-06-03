# FuckYouXcode

## blablabla🥱
起因是在Netflix和Disney plus上看剧时想边看剧边截图学习单词，但是因为屏幕保护，截出来的图只有纯字幕，所以便想着做一个app，来批量进行OCR识别并筛选出真正需要的单词，进行高效学习。但是后来功能越做越多。

## 概述
一个基于 SwiftUI 构建的 iOS 英语学习应用，面向需要即时查词和词汇管理的英语学习者。内置 SQLite 英汉词典，并支持导入外部 MDict 格式词典（如牛津高阶英汉双解词典）。用户可通过文本搜索、拍照 OCR 识别或 AI 对话助手三种方式查词。支持生词收藏、词汇本管理、多词典切换。附带的 Python 本地服务器和浏览器扩展，可通过 HTTP API 和 MCP（模型上下文协议）将词典功能延伸至桌面浏览器。

## 架构总览

```mermaid
flowchart TD
    %% ===== 入口 =====
    APP["<b>FuckYouXcodeApp.swift</b><br/>@main 入口<br/>初始化全局状态"]

    %% ===== 状态层 =====
    APP --> STATE["<b>AppState.swift</b><br/>启动数据库、创建<br/>词典服务、管理目录"]
    APP --> SELECTION["<b>SelectionManager.swift</b><br/>文本选区状态"]
    APP --> AI_STORE["<b>AISettingsStore.swift</b><br/><b>AIChatHistoryStore.swift</b><br/>AI 配置与历史记录"]

    %% ===== 视图层 =====
    STATE --> CV["<b>ContentView.swift</b><br/>根 TabView"]
    SELECTION --> CV

    %% ===== 三个 Tab =====
    CV --> TAB_OCR["<b>SearchWordsFromVideosView</b><br/>Tab 1: 拍照识词"]
    CV --> TAB_COLLECTION["<b>WordsCollectionView</b><br/>Tab 2: 生词本"]
    CV --> TAB_SEARCH["<b>DictionaryRootView</b><br/>Tab 3: 词典搜索"]

    %% ===== Tab 1: OCR =====
    TAB_OCR --> OCR_SVC["<b>OCRService.swift</b><br/>OCR 文字识别"]
    TAB_OCR --> EXTRACTOR["<b>WordExtractor.swift</b><br/>从文本中提取单词"]
    TAB_OCR --> SEL_TEXT["<b>SelectableText.swift</b><br/>可选文本组件"]
    TAB_OCR --> OFF_DICT["<b>OfficialDictionaryEntryView.swift</b><br/>iOS 系统词典封装"]

    %% ===== Tab 2: 生词本 =====
    TAB_COLLECTION --> WC_DETAIL["<b>WordCollectionDetailView.swift</b><br/>生词本详情"]
    TAB_COLLECTION --> USER_SVC["<b>UserDataService.swift</b><br/>(Actor) 收藏与生词本增删改查"]
    USER_SVC --> USER_DB["<b>UserDB.swift</b><br/>用户数据库 SQLite / GRDB"]
    USER_SVC --> SYNC["<b>UserCloudSyncService.swift</b><br/>iCloud 同步（暂未启用）"]
    USER_SVC --> PATHS["<b>UserStoragePaths.swift</b><br/>应用存储路径管理"]

    %% ===== Tab 3: 词典搜索 =====
    TAB_SEARCH --> SEARCH_VIEW["<b>DictionarySearchView.swift</b><br/>搜索栏与联想建议"]
    SEARCH_VIEW --> DICT_SVC["<b>DictionaryService.swift</b><br/>核心查词引擎"]

    %% ===== 词典引擎 =====
    DICT_SVC --> DICT_DB["<b>DictionaryDB.swift</b><br/>内置词典 SQLite / GRDB"]
    DICT_SVC --> ENTRY_VIEW["<b>DictionaryEntryView.swift</b><br/>词条详情展示"]

    %% ===== MDict HTML 渲染 =====
    ENTRY_VIEW --> HTML_VIEW["<b>MDictHTMLView.swift</b><br/>WKWebView 封装"]
    HTML_VIEW --> SCHEME["<b>MDictAssetSchemeHandler.swift</b><br/>dict:// URL 处理"]
    HTML_VIEW --> BRIDGE["<b>MDictHTMLSelectionBridge.swift</b><br/>文本选中 JS 桥接"]
    HTML_VIEW --> NORM["<b>HTMLPlainTextNormalizer.swift</b><br/>HTML 转纯文本"]

    %% ===== 词典导入 =====
    STATE --> CATALOG["<b>DictionaryCatalogStore.swift</b><br/>导入词典目录记录"]
    STATE --> IMPORTER["<b>DictionaryImportIndexer.swift</b><br/>外部词典导入器"]
    IMPORTER --> MDX["<b>MDXParser.swift</b><br/>MDX 格式解析"]
    IMPORTER --> MDD["<b>MDDParser.swift</b><br/>MDD 资源解析"]

    %% ===== AI 对话 =====
    AI_STORE --> AI_VIEWS["<b>AIChatViews.swift</b><br/>AI 对话界面"]
    AI_VIEWS --> AI_CLIENT["<b>OpenAIChatClient.swift</b><br/>OpenAI API 调用"]
    AI_CLIENT --> AI_MODEL["<b>AIChatModels.swift</b><br/>消息数据模型"]

    %% ===== 浏览器桥接（独立系统） =====
    subgraph BRIDGE[" 浏览器桥接（Python 配套服务） "]
        direction TB
        HTTP["<b>dictionary_server.py</b><br/>本地 HTTP 服务 :8765"]
        MCP["<b>fuckyouxcode_mcp_server.py</b><br/>MCP stdio 服务"]
        EXTENSION["<b>atlas_extension/</b><br/>Chromium 浏览器扩展"]
        HTTP --> EXTENSION
        MCP --> EXTENSION
    end
```
