# Windows Desktop App Launcher (PySide6/Qt)

## 问题
pythonw.exe + PySide6 经常无法显示GUI窗口（静默失败）。
VBS直接调用pythonw.exe时，Qt平台插件可能初始化失败。

## 推荐方案：.bat + VBS + .lnk 快捷方式

### 1. 创建 start.bat
```bat
@echo off
cd /d "C:\path\to\project"
"C:\path\to\python.exe" "C:\path\to\project\app.py"
```

### 2. 创建 launch.vbs（隐藏控制台窗口）
```vbs
Set objShell = CreateObject("WScript.Shell")
objShell.Run "cmd.exe /c ""C:\path\to\project\start.bat""", 0, False
```

### 3. 创建 .lnk 快捷方式
**方法A：PowerShell脚本（.ps1文件，SCP到远程执行）**
```powershell
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("C:\Users\Administrator\Desktop\AppName.lnk")
$Shortcut.TargetPath = "C:\Windows\System32\wscript.exe"
$Shortcut.Arguments = "C:\path\to\project\launch.vbs"
$Shortcut.WorkingDirectory = "C:\path\to\project"
$Shortcut.IconLocation = "C:\Windows\System32\shell32.dll,136"
$Shortcut.Description = "App Description"
$Shortcut.Save()
```

**方法B：VBS脚本创建快捷方式（处理中文名更可靠）**
```vbs
Set WshShell = CreateObject("WScript.Shell")
Set Shortcut = WshShell.CreateShortcut("C:\Users\Administrator\Desktop\AppName.lnk")
Shortcut.TargetPath = "C:\Windows\System32\wscript.exe"
Shortcut.Arguments = "C:\path\to\project\launch.vbs"
Shortcut.WorkingDirectory = "C:\path\to\project"
Shortcut.IconLocation = "C:\Windows\System32\shell32.dll,136"
Shortcut.Description = "App Description"
Shortcut.Save
```

## Pitfalls

- **pythonw.exe + Qt = 常见失败**：Qt平台插件在pythonw下可能静默崩溃。用python.exe + VBS隐藏窗口更可靠。实测：python.exe正常显示GUI，pythonw.exe进程启动但窗口不显示。
- **VBS中的引号**：VBS字符串中的双引号用 `""` 转义，不是 `\"`
- **.lnk图标**：`shell32.dll,136` 是相机图标；`imageres.dll,101` 是齿轮；`shell32.dll,22` 是文件夹
- **不要用PowerShell的Out-File写VBS**：会破坏引号和编码，用write_file工具直接写
- **VBS中python路径必须用完整路径**：VBS运行时PATH可能不包含Python目录
- **VBS中不要用GetParentFolderName**：桌面快捷方式中WScript.ScriptFullName指向VBS所在目录（桌面），不是项目目录。用绝对路径。
- **通过SSH创建.lnk**：中文文件名在SSH中会乱码。解决方案：(1) 写.ps1脚本文件，SCP到远程，用`powershell -ExecutionPolicy Bypass -File script.ps1`执行；(2) 或用VBS脚本的COM对象创建（VBS编码比PowerShell更可靠）；(3) **快捷方式文件名用英文**（如`WatermarkTool.lnk`），中文名在SSH传输中会损坏。不要在SSH命令中内嵌中文here-string。
- **PowerShell创建.lnk中文名损坏**：即使.ps1脚本正确执行并返回"OK"，.lnk文件的显示名可能仍是乱码。用VBS的`CreateShortcut`+`Save`更可靠（VBS原生处理Unicode）。实测：PowerShell创建的中文名.lnk显示为乱码，VBS创建的显示正确。
- **启动前杀旧进程**：多次启动会累积python进程。先`tasklist | findstr python`检查，再`taskkill /F /PID <pid>`清理。
- **不要用PowerShell here-string通过SSH写文件**：SSH会吞掉here-string的引号和特殊字符。用write_file本地写再SCP，或用echo逐行追加。

## 远程部署流程

```bash
# 1. 创建目录
ssh target "mkdir -p C:\Users\Administrator\app-name"

# 2. 复制文件
scp -r ./app target:"C:\Users\Administrator\app-name\\"

# 3. 安装依赖
ssh target "pip install PySide6 opencv-python ..."

# 4. 写start.bat（用echo避免编码问题）
ssh target "echo @echo off > C:\path\start.bat"
ssh target "echo cd /d C:\path >> C:\path\start.bat"
ssh target "echo C:\python.exe C:\app.py >> C:\path\start.bat"

# 5. SCP launch.vbs（用write_file本地写再scp）

# 6. 创建.lkn（写.ps1本地再scp再执行）

# 7. 验证GUI启动
ssh target "python -c \"import sys; sys.path.insert(0, r'C:\path'); from ui.main_window import MainWindow; from PySide6.QtWidgets import QApplication; app=QApplication([]); w=MainWindow(); w.show(); print('OK'); sys.exit(0)\""
```
