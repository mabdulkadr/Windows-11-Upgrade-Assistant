<div align="center">

# 🪟 Windows 11 Upgrade Assistant

**Controlled in-place upgrades to Windows 11**

Readiness checks, ISO handling, preset setup profiles, and a full command preview — apps, files, and settings preserved. Unsupported hardware? It can install Windows 11 anyway.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![PowerShell](https://img.shields.io/badge/powershell-5.1%2B-blue.svg)
![Platform](https://img.shields.io/badge/Windows-10%2F11-blue.svg)
![UI](https://img.shields.io/badge/UI-WPF%20GUI-blue.svg)
![Version](https://img.shields.io/badge/version-1.1-green.svg)

[Features](#-core-features) • [Usage](#-usage) • [Requirements](#️-requirements) • [Troubleshooting](#-troubleshooting)

</div>

---

# 📖 Overview

**Windows 11 Upgrade Assistant** is a modern WPF-based PowerShell tool that helps any user run a controlled in-place upgrade to Windows 11 while preserving apps, files, and settings — and it can remove the restrictions that block installing Windows 11 on unsupported hardware. Old PC? No TPM, no Secure Boot, unsupported CPU? It lets you install Windows 11 anyway.

It provides a clean workflow to:

* Run quick **readiness checks** (RAM, Disk, AC power)
* Validate **Windows setup media** by selecting `setup.exe` (USB / mounted ISO)
* Mount an ISO and auto-detect `setup.exe`
* Choose from safe **Setup Profiles** (preset command templates)
* Preview the exact **planned command**, then **confirm and audit** it in a dedicated dialog before launch
* Launch Windows Setup with clear status feedback
* Auto-dismount the ISO and clean up on window close
* **Session transcript logging** to `%LOCALAPPDATA%\Win11UpgradeAssistant\Logs\`

---

## 🖼️ Screenshots

![Windows 11 Upgrade Assistant main window — device details, readiness checks, media path, and setup profiles](Screenshot.png)

*Main window: device & OS details, readiness pills, media validation, setup profile selection, and the planned command preview.*

---

# ✨ Core Features

### 🔹 Device & Readiness
* **Device & OS details** — Windows Edition (build-aware normalisation for 22000+), Version, Build (UBR), Install Date, hardware model
* **Readiness checks** with pass/fail pills: **RAM** (min 8 GB), **Free Disk C:** (min 30 GB), **AC Power** (best-effort; desktops OK)
* **One-click Re-check** — the device scan runs on a dedicated MTA runspace, so the UI never freezes on slow WMI queries

### 🔹 Media Validation & ISO Actions
* **Browse** to a valid `setup.exe` (filename enforced, field highlights green when valid) or **Clear** to reset
* **Choose ISO** → mounts the image and auto-fills the `setup.exe` path
* **Unmount ISO** → releases the drive letter after the upgrade
* **Download ISO** → opens the official Microsoft Windows 11 download page

### 🔹 Setup Profiles & Command Control
* **Preset profiles:**
  * **Option 1 – Basic** — clean-style flow with driver migration
  * **Option 2 – Standard In-Place Upgrade (default)** — keeps data/apps, logs to `C:\WinSetup.log`
  * **Option 3 – Silent In-Place Upgrade** — quiet mode, no OOBE, no reboot (media/policy dependent)
* **Planned command preview** — shows the exact `<setup.exe> <args>` before anything runs
* **Extra arguments** — optional custom Windows Setup switches, with an official docs link
* **Confirm-before-launch dialog** — the full command, with **Launch / Copy / Cancel**

### 🔹 Safe Launch Behavior
* If not elevated, the tool offers **Run as Administrator** (Yes / Continue / Cancel)
* Clear status messages for common failures: missing file, blocked execution, access denied, UAC cancelled, AppLocker/Defender block
* Elevation state clearly shown in the sidebar

### 🔹 Session Logging
* Every run captures a `Start-Transcript` log:

```text
%LOCALAPPDATA%\Win11UpgradeAssistant\Logs\Session_yyyyMMdd_HHmmss.log
```

* The transcript closes cleanly on window close, and the ISO is auto-dismounted on exit

---

# 🚀 Usage

### Launch

**Option 1 — PowerShell script:**

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Windows-11-Upgrade-Assistant-v1.1.ps1
```

**Option 2 — Packaged EXE (self-signed with PSWrap):**

```text
Windows-11-Upgrade-Assistant-v1.1.exe
```

The `.exe` was compiled and self-signed using [PSWrap](https://github.com/mabdulkadr/PSWrap) — no PowerShell console required.

### Typical Workflow

1. Launch the tool
2. Review **Device & OS Details** + **Readiness Checks**
3. **Browse** and select `setup.exe` from mounted ISO or USB media (or **Choose ISO** to auto-mount)
4. Select the desired **Setup profile** preset
5. *(Optional)* add **Extra arguments**
6. Verify the **Planned command** preview
7. Click **Start Upgrade** → review the full command in the confirmation dialog → **Launch** / **Copy** / **Cancel**
8. *(Optional)* **Unmount ISO** after the upgrade; closing the window auto-dismounts and finalises the log

---

# ⚙️ Requirements

| Requirement | Details |
|-------------|---------|
| **OS** | Windows 10 / 11 |
| **PowerShell** | Windows PowerShell 5.1 (7+ also works) |
| **ISO mounting** | Windows built-in |
| **Permissions** | Standard user can open the UI and browse media; **Administrator** recommended for launching `setup.exe` reliably (elevation state shown in the sidebar) |

### Files & Logs

```text
Windows-11-Upgrade-Assistant\
├── Windows-11-Upgrade-Assistant-v1.1.ps1
├── Windows-11-Upgrade-Assistant-v1.1.exe
├── README.md
└── Screenshot.png

%LOCALAPPDATA%\Win11UpgradeAssistant\Logs\Session_<timestamp>.log
```

---

# 🔍 Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| "Checks failed" pill stays red | WMI service disabled or running without admin | Enable `Winmgmt` and re-run elevated |
| ISO mounts but no `setup.exe` path filled | ISO is not Windows installation media | Use a different ISO |
| "Access denied" on launch | Standard user without UAC bypass | Click **Run as admin** in the elevation prompt |
| UI freezes when scanning | Fixed in v1.0.5+ via MTA runspace | Update to v1.1 |

---

# 🛡 Operational Notes

* Presets may include switches like `/Product server` and `/compat IgnoreWarning` — use relaxed compatibility options only if approved by organizational policy
* Always test on **pilot devices** before broad rollout
* Ensure your Windows media matches target language/edition requirements
* Session logs are written **unencrypted** to a per-user folder — do not include secrets in the Extra Arguments field
* The background runspace runs as **MTA** intentionally: WMI/CIM is faster on MTA and the UI thread stays STA

---

## 👤 Author

**Mohammad Abdulkader Omar**  
GitHub: [@mabdulkadr](https://github.com/mabdulkadr)  
Website: [momar.tech](https://momar.tech)  

---

## 📜 License

This project is licensed under the [MIT License](LICENSE).

---

## ⚠ Disclaimer

This skill and every script it generates are provided as-is with no warranty
of any kind. Test generated tools in a staging environment before deploying to
production. The authors assume no liability for any damage or data loss
resulting from their use.

---

<div align="center">

⭐ **If this tool saves you time, star the repo — it helps others find it.**

[Report an Issue](../../issues) · [momar.tech](https://momar.tech)

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mabdulkadrx)

Built with [**PowerShell Enterprise Admin**](https://github.com/mabdulkadr/powershell-enterprise-admin-skill)

</div>
