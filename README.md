# 简账 · 现代 iOS 记账 App

一款纯本地、无网络请求的 SwiftUI 记账应用，支持 **快捷指令识图记账** 和 **App 密码 / 面容 ID 锁**。

- 最低系统：iOS 17
- 技术栈：SwiftUI · SwiftData · Swift Charts · App Intents · Vision（设备端 OCR）· LocalAuthentication
- App 名称：**简账**（`CFBundleDisplayName`），Bundle ID：`com.fve.ledger`（可改，见下文）
- 产物：GitHub Actions 在 macOS 上编译出 **未签名** 的 `JianZhang-unsigned.ipa`，自行签名安装

---

## 功能

### 记账
- 收入 / 支出记录的新增、编辑、删除（左滑删除 / 编辑）
- 字段：金额、分类、备注、商户、账户（可选：现金 / 支付宝 / 微信 / 银行卡…）、时间
- 编辑页可「从支付截图识别填写」（相册选图，本机 OCR）
- 自定义分类：名称、SF Symbols 图标、颜色（预设色 + 取色器），拖动排序；内置 12 个支出分类和 6 个收入分类
- 首页：月度结余 / 收入 / 支出汇总卡片、预算进度，按天分组的明细（每天显示当日收支），左右切换月份
- 统计：月度 / 年度切换；分类饼图（环形图）+ 分类排行（可点进看明细）；每日 / 每月趋势柱状图；年度收支对比图；日均支出、笔数
- 每月预算：首页和统计页显示进度，超 80% 变橙、超支变红
- 搜索 / 筛选：关键词（备注、商户、分类、账户、金额）、收支类型、分类、日期范围、金额区间
- CSV 导出（UTF-8 BOM，Excel 直接打开不乱码），通过系统分享面板保存到「文件」或发送
- 外观：跟随系统 / 浅色 / 深色；货币符号可选

### 应用锁
- 可选 4 / 5 / 6 位数字密码，**加盐 + 多轮 SHA-256 哈希后存入钥匙串**（`WhenUnlockedThisDeviceOnly`，不同步 iCloud），明文不落盘
- 可选面容 ID / 触控 ID 解锁（需先设置密码；开启时会先验证一次）
- 启动时、以及从后台返回时显示锁屏；可设置「离开后多久需要解锁」（立即 / 30 秒 / 1 / 5 / 15 分钟 / 1 小时）
- 连续输错 5 次后逐级锁定（30 秒起，翻倍递增）
- 修改密码、关闭密码都必须先输入当前密码
- 多任务界面隐私遮罩：App 进入非活跃状态时自动遮挡内容（可关闭）
- 锁屏与遮罩使用独立的高层级窗口，即使当时打开着编辑页等弹窗也能完全遮住

### 快捷指令 / Siri（App Intents）
| 操作 | 说明 |
| --- | --- |
| **识图记账** | 传入图片（截屏 / 照片），本机 OCR 识别金额、商户、时间并猜测分类后自动记一笔。可选参数：保存前确认、指定分类、收支类型、备注。返回识别到的金额。 |
| **记一笔** | 参数：金额、收支类型、分类、备注、时间。 |
| **本月收支** | 语音 / 对话框播报本月支出、收入、结余与预算剩余。 |

Siri 短语示例：「用简账识图记账」「简账记一笔」「简账本月收支」。

识图规则（`Ledger/OCR/ReceiptParser.swift`）：
- 金额：识别 `¥ / ￥ / RMB / 人民币 / 元`、正负号、千分位；优先「实付款 / 实付 / 支付金额 / 付款金额 / 合计 / 总计 / 交易金额」等关键词后（或下一行）的数字；降低「优惠 / 抵扣 / 余额 / 运费 / 原价」等附近数字的权重；自动排除日期、时间、订单号、卡号尾号、百分比、数量
- 收支：金额带 `-` 记支出，带 `+` 或出现「收款到账 / 退款成功 / 已存入零钱」等记收入，否则默认支出
- 商户：「商户全称 / 收款方 / 交易对方 / 商品说明…」后的文字，否则取金额上方最像名称的一行
- 时间：`2026-10-17 08:45`、`2026年10月16日 19:20`、`10月12日 12:30`、`昨天 18:05` 等；没有就用当前时间
- 分类：按关键词猜测（美团 / 星巴克 → 餐饮，滴滴 / 加油 / 12306 → 交通，淘宝 / 京东 / 超市 → 购物，电影 / 游戏 → 娱乐，电费 / 水费 / 燃气 → 生活缴费……），找不到则归入「其他」

---

## 编译（GitHub Actions）

仓库自带 `.github/workflows/build.yml`：

1. 把本目录推送到你自己的 GitHub 仓库（私有仓库也可以）。
2. 每次 push 都会在 `macos-15` 上：选择最新稳定版 Xcode → `brew install xcodegen` → `xcodegen generate` → `xcodebuild archive`（关闭签名）→ 打包 `Payload/Ledger.app` 为 `JianZhang-unsigned.ipa`。
3. 在 Actions 运行页面底部 **Artifacts** 下载 `JianZhang-unsigned-ipa`（解压后得到 ipa）。
4. 推送 `v*` 标签（如 `git tag v1.0.0 && git push --tags`）时会自动创建 GitHub Release 并附上 ipa。
5. 也可以在 Actions 页面手动运行（workflow_dispatch），并填写自定义 Bundle ID。

> Xcode 工程由 `project.yml` 生成，不提交 `.xcodeproj`。本地有 Mac 时：`brew install xcodegen && xcodegen generate && open Ledger.xcodeproj`。

修改 Bundle ID / 版本号：编辑 `project.yml` 中的 `PRODUCT_BUNDLE_IDENTIFIER`、`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION`。

---

## 签名与安装

ipa 未签名，任选一种方式安装：

- **爱思助手**：工具箱 → IPA 签名 → 导入 ipa → 使用 Apple ID 签名（免费账号 7 天有效）→ 安装到设备。
- **Sideloadly**（Windows / macOS）：连接 iPhone，拖入 ipa，填写 Apple ID，点 Start。免费账号需每 7 天重签。
- **AltStore / SideStore**：在 AltStore 中「My Apps → ＋」选择 ipa，AltStore 会自动续签。
- **自有证书**（个人 / 企业开发者账号）：用 `zsign`、`ios-app-signer` 或 Xcode 重签：
  ```bash
  zsign -k dev.p12 -p 证书密码 -m dev.mobileprovision -o JianZhang-signed.ipa JianZhang-unsigned.ipa
  ```
  描述文件的 App ID 需与 Bundle ID 一致（或使用通配符）。

安装后首次打开如提示「未受信任的开发者」：设置 › 通用 › VPN 与设备管理 › 信任对应开发者。iOS 16+ 还需在 设置 › 隐私与安全性 中打开 **开发者模式**。

> 免费 Apple ID 签名的应用，部分系统功能（如 Siri 短语）可能需要打开一次 App 后才会出现在「快捷指令」中。重签时如果 Bundle ID 变了，数据会被视为另一个 App 的数据（不会互通）。

---

## 设置「识图记账」快捷指令

App 内 设置 › 快捷指令 › 识图记账设置教程 里也有同样的步骤。

**方案一：轻点背面 / 操作按钮，一键截屏记账（推荐）**
1. 打开「快捷指令」App → 右上角 ＋ 新建。
2. 添加操作 **截屏**。
3. 添加操作 **识图记账**（搜索「简账」），「图片」参数会自动连接上一步的截屏。
4. 可选：打开「保存前确认」，识别后会先弹窗让你确认；也可以固定一个分类。
5. 命名为「识图记账」。
6. 设置 › 辅助功能 › 触控 › **轻点背面** → 轻点两下 → 选择该快捷指令；iPhone 15 Pro 及以上也可在 设置 › **操作按钮** → 快捷指令 中绑定。

之后停在支付宝 / 微信的支付成功页，轻点两下手机背面即可自动记账，顶部会弹出「已记账：支出 ¥35.00 · 餐饮 · 星巴克 · 10月18日 12:30」。

**方案二：从相册选择**：「选择照片」→「识图记账」。

**方案三：共享表单**：在快捷指令详情里打开「在共享表单中显示」，接收「图像」，下一步「识图记账」，就能在相册里分享截图来记账。

识别不准时，可以在首页点开这条记录修改。

---

## 隐私说明

- **所有数据只保存在本机**（SwiftData 本地数据库），不包含任何网络请求代码，不接入任何统计 / 广告 SDK。
- **OCR 在设备上完成**（Apple Vision 框架），截图不会离开手机，App 也不会保存截图本身。
- 密码只以加盐哈希形式存于钥匙串，且仅本设备可用。
- 只申请面容 ID 权限（用于解锁）；相册通过系统照片选择器按需选图，不读取整个相册。
- **注意**：快捷指令 / Siri 的「识图记账」「记一笔」「本月收支」在后台运行、不显示界面，因此 **不需要输入 App 密码**；但它们都设置了 `authenticationPolicy = .requiresAuthentication`，需要 iPhone 本身已解锁才能运行。如果在意「本月收支」被他人通过 Siri 听到，可以在「快捷指令」App 中关闭该 App 的 Siri 建议。
- 数据备份：请定期在 设置 › 数据 › 导出 CSV。卸载 App 会删除所有数据。

---

## 目录结构

```
ledger-app/
├── project.yml                     # XcodeGen 配置（iOS 17，Swift 5 语言模式）
├── Config/Info.plist               # 显示名、面容 ID 用途说明等
├── .github/workflows/build.yml     # 未签名 ipa 构建 + Release
├── Ledger/
│   ├── App/                        # 入口、根视图、Tab
│   ├── Models/                     # SwiftData 模型、共享 ModelContainer、默认分类
│   ├── Views/                      # 首页、记账编辑、统计、搜索、设置、分类管理、教程
│   ├── Security/                   # 钥匙串、密码哈希、应用锁、锁屏 / 隐私遮罩窗口
│   ├── Intents/                    # App Intents：识图记账、记一笔、本月收支、AppShortcuts
│   ├── OCR/                        # Vision 文字识别 + 纯 Swift 解析器
│   ├── Utilities/                  # 格式化、颜色、CSV
│   └── Resources/Assets.xcassets   # App 图标（占位）、强调色
└── Tools/
    ├── make_icon.py                # 重新生成占位图标
    └── ParserCheck/main.swift      # 解析器自检（可在 Linux / macOS 运行）
```

解析器自检：
```bash
swiftc Ledger/OCR/ReceiptParser.swift Tools/ParserCheck/main.swift -o /tmp/parsercheck && /tmp/parsercheck
```
