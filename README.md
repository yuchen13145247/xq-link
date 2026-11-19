# 象棋连线（XiangqiLink）

自己做的象棋「连线」App：内置 Pikafish 引擎 + 往对面 App 注入落子。
编译在 GitHub Actions 的 macOS runner 上做，**你本地不需要 Mac**；装包用巨魔（TrollStore）。

## 现在的功能（v1）

- 内置 Pikafish（UCI，NNUE 权重随包带），输入/粘贴 FEN → 出最佳着法
- 棋盘标定：点两个对角交叉点，之后按 9×10 网格换算屏幕坐标
- 一键落子：把 `bestmove` 拆成「起点格 + 终点格」两次注入点击 → 对面走棋
- 注入走私有 `IOHIDEventSystemClient`，靠 entitlements 生效（巨魔签名时打进去）

**v2 待做**：ReplayKit 广播扩展（自动读屏）+ 棋子识别（模板匹配 → CoreML 小模型），
识别出来后就不用手贴 FEN 了。

## 你要做的三步

### 1. 传上去

```powershell
# 装 Git for Windows 后，在 xq-link 目录里
git init
git add .
git commit -m "xiangqi link v1"
git branch -M main
git remote add origin https://github.com/<你的账号>/xq-link.git
git push -u origin main
```

推上去后 GitHub Actions 自动跑（`build-ipa`），大约 10–15 分钟，
在 Actions → 运行记录 → Artifacts 里下 `XiangqiLink-ipa`，就是 `.ipa`。

> 首次推上去大概率会挂一两处（引擎代码版本差异、编译参数），
> 把 Actions 里红色那步的日志贴给我，我按报错改。通常 2–3 轮就能出包。

### 2. 签名安装（巨魔）

`xcodebuild` 出来的是**未签名**包，直接用巨魔装：

1. iPhone 上打开 TrollStore → `+` → 选 `XiangqiLink.ipa`
2. 如果提示缺少 entitlements：把 `XiangqiLink/XiangqiLink.entitlements` 一起给 TrollStore
   （TrollStore 设置里开 “ldid”，会自动用它自己的权限签名）
3. 装完进 App，「注入能力」显示**可用**就说明私有权限拿到了

非巨魔设备只能走 Sideloadly 自签，7 天一次，而且**注入会失效**（没有私有 entitlement），
那种情况下只能用「计算最佳着法」，手动照着下。

### 3. 用

1. 「标定棋盘」→ 点你对面棋盘最左上那个交叉点，再点最右下那个交叉点
2. 把当前局面 FEN 贴进去（红方在下、黑方在上）
3. 「计算最佳着法」→ 出 `h2e2` 这种
4. 「把最佳着法落到对面」→ 自动点两下

## 目录

```
project.yml                      XcodeGen 工程描述（不用手写 pbxproj）
XiangqiLink/
  XiangqiLinkApp.swift           入口，启动时加载 nnue 起引擎
  ContentView.swift              界面：FEN、深度、标定、落子
  Engine/engine_shim.h/.cpp      Pikafish UCI 封装（管道 + 读线程）
  Engine/Pikafish.swift          Swift 侧封装
  Inject/TouchInjector.swift     私有 IOHID 注入
  XiangqiLink.entitlements       巨魔签名用的权限
.github/workflows/ios.yml        云端编译 + 打包 IPA
```

## 已知风险

| 风险 | 说明 |
|---|---|
| Pikafish 源码版本漂移 | `UCI::loop` 接口稳定，编译参数可能要跟着改（`NNUE_EMBEDDING_OFF` 等） |
| 私有 API 签名 | `IOHIDEventCreateDigitizerEvent` 的参数顺序 iOS 各版本一致，但我没法在本机验证，跑不通就看日志里的 `injector ready` |
| 巨魔版本 | TrollStore 需要对应 iOS 版本支持（一般 ≤ iOS 17.0），17.x 部分机型不行 |
| GPL | Pikafish 是 GPLv3，自己用没问题，要分发就把源码一起带上 |
