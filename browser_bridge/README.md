# FuckYouXcode Atlas Dictionary Bridge

这是一版最小可用原型：

- 浏览器右键选中文本
- 出现菜单项 `用 FuckYouXcode 查词`
- 打开 Chromium/Atlas 侧边栏
- 侧边栏通过本地服务查询 app 的词典数据库
- 支持读取 imported dictionary catalog 并切换词典
- 如果词典带 `entry_html`，侧边栏会优先用 iframe 展示词条正文

## 目录

- `dictionary_server.py`: 本地 companion 服务
- `fuckyouxcode_mcp_server.py`: OpenClaw/Codex/Claude Code 等 MCP client 可调用的 stdio MCP server
- `atlas_extension/`: Chromium/Atlas 扩展目录

## 启动本地服务

在仓库根目录运行：

```bash
python3 browser_bridge/dictionary_server.py
```

或者直接运行：

```bash
./browser_bridge/start_bridge.sh
```

默认会按这个顺序找词库：

1. 环境变量 `FUCKYOUXCODE_DICT_DB`
2. 最近的 iOS Simulator app container 里的 `Library/Application Support/dic_.db`
3. 仓库内的 `Resources/dic_.db`
4. `~/Library/Application Support/dic_.db`

用户数据默认会按这个顺序找：

1. 环境变量 `FUCKYOUXCODE_USER_DB`
2. 最近的 iOS Simulator app container 里的 `Library/Application Support/user_1.db`
3. 仓库内的 `Resources/user_1.db`
4. `~/Library/Application Support/user_1.db`

如果你想让 bridge 读取自定义词典目录文件，可以设置：

- `FUCKYOUXCODE_DICTIONARY_CATALOG`

服务默认监听：

- `http://127.0.0.1:8765`

可用接口：

- `GET /health`
- `GET /api/dictionaries`
- `GET /api/lookup?word=hello&dictionaryId=builtin.default`
- `GET /api/suggestions?q=hel&dictionaryId=builtin.default`
- `GET /api/user/favorites?limit=50&offset=0`
- `GET /api/user/word-state?word=hello&dictionaryId=builtin.default`
- `GET /api/user/word-groups`
- `POST /api/user/set-favorite` with JSON `{"word":"hello","favorite":true}`
- `POST /api/user/add-word-to-group` with JSON `{"word":"hello","groupId":1}`
- `GET /render/entry/<dictionaryId>/<entryKey>`
- `GET /render/asset/<dictionaryId>/<path>`

## OpenClaw MCP

在 OpenClaw 里把这个 stdio MCP server 注册成外部工具：

```bash
openclaw mcp set fuckyouxcode '{"command":"python3","args":["/Users/mayifan/Desktop/iOS app/FuckYouXcode/browser_bridge/fuckyouxcode_mcp_server.py"]}'
```

如果要显式指定数据库：

```bash
openclaw mcp set fuckyouxcode '{"command":"python3","args":["/Users/mayifan/Desktop/iOS app/FuckYouXcode/browser_bridge/fuckyouxcode_mcp_server.py","--db","/Users/mayifan/Desktop/iOS app/FuckYouXcode/Resources/dic_.db","--user-db","/Users/mayifan/Desktop/iOS app/FuckYouXcode/Resources/user_1.db"]}'
```

MCP 工具：

- `dictionary_lookup`
- `dictionary_suggestions`
- `dictionary_list_dictionaries`
- `user_list_favorites`
- `user_get_word_state`
- `user_set_favorite`
- `user_list_word_groups`
- `user_add_word_to_group`

## 安装扩展

在支持 Chromium 扩展的浏览器中加载：

- 打开扩展管理页
- 开启开发者模式
- 选择“加载已解压的扩展”
- 选中 `browser_bridge/atlas_extension`

如果 Atlas 的扩展 UI 和 Chrome 略有不同，思路一样：导入这个扩展目录即可。

## 当前限制

- 这是浏览器第一版，不是把原生 SwiftUI `DictionaryEntryView` 直接嵌进 Atlas。
- 当前侧边栏展示的是网页版词条卡片；如果 imported 词典带 HTML，会优先显示 sandboxed iframe。
- 目前走的是本地 companion 服务，不是直接从 iOS app 进程里暴露接口。
- 用户收藏、高亮、批注、分组已经通过 HTTP/MCP bridge 暴露；浏览器侧边栏暂时仍以查词显示为主。
- MDict 复杂跳转和极个别资源引用规则，还没有完全做到和 `WKWebView + dict://` 一样的兼容度。

## 下一步建议

下一轮如果继续做，优先级建议是：

1. 把本地服务从 Python 原型迁成 Swift/macOS helper
2. 复用现有 Swift `DictionaryService`，避免 Python 侧维护一份近似逻辑
3. 把 imported 词典的资源跳转兼容性继续补齐
4. 视需要把 iOS 工程迁到 Mac Catalyst 或补一个原生 macOS companion app
