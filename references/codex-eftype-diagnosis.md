# Codex CLI Windows EFTYPE 错误诊断参考

## 场景

Windows 10 本机，Codex CLI v0.144.6 通过 npm 全局安装。运行任何 `codex` 命令（包括 `--version`）报：

```
Error: spawn EFTYPE
    at ChildProcess.spawn (node:internal/child_process:420:11)
    at spawn (node:child_process:753:9)
    at .../@openai/codex/bin/codex.js:195:15
  errno: -4028,
  code: 'EFTYPE',
  syscall: 'spawn'
```

## 诊断过程

### 1. 确认安装位置

```
where codex
```
→ 多个位置，PATH 顺序：
1. `.../TRAE SOLO CN/ModularData/ai-agent/vm/tools/node/codex`（Trae IDE 自带）
2. `.../AppData/Roaming/npm/codex`（npm 全局安装）

### 2. 检查平台相关包

```javascript
// 检查 @openai/codex-win32-x64 是否存在
try {
  require.resolve('@openai/codex-win32-x64/package.json');
} catch(e) {
  // 不存在则报 "Cannot find module"
}
```

### 3. 检查二进制文件

```javascript
const path = require('path');
const fs = require('fs');
const d = path.join(
  path.dirname(require.resolve('@openai/codex-win32-x64/package.json')),
  'vendor', 'x86_64-pc-windows-msvc', 'bin', 'codex.exe'
);
console.log('exists?', fs.existsSync(d));  // true
console.log('size:', fs.statSync(d).size); // ~54MB
```

二进制文件存在但 `spawn()` 失败 → EFTYPE 意味着文件不是有效 Windows 可执行映像（损坏）。

### 4. 与正常安装对比

正常安装的目录结构：
```
node_modules/@openai/
  codex/                    # CLI 入口 (codex.js)
  codex-win32-x64/          # Windows 原生二进制
    vendor/
      x86_64-pc-windows-msvc/
        bin/
          codex.exe          # ~54MB, 主二进制
          codex-code-mode-host.exe  # ~53MB, 辅助进程
        codex-resources/
          codex-command-runner.exe
          codex-windows-sandbox-setup.exe
```

## 修复

```bash
npm uninstall -g @openai/codex
npm install -g @openai/codex
```

重装后验证：
```bash
codex --version  # 应正常输出版本号
```

## 注意事项

- EFTYPE 错误发生在 `codex.js` 内部 `spawn()` 调用时，不是 shell wrapper 的问题
- 直接用 `node codex.js` 也会报相同错误
- 不能用 `cmd.exe /c` 或任何 shell 绕过方式解决
- 如果 `codex.exe` 损坏但 `codex-code-mode-host.exe` 正常，也是同样的症状
- Trae IDE 自带的 Codex 版本（在 `TRAE SOLO CN/...` 路径下）可能缺少 platform 包，优先使用 npm 全局安装的版本
