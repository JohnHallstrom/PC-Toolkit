# PC Toolkit

Finds out why a Windows computer is slow and fixes what can be fixed safely, without reinstalling Windows.

## Quick start (no technical knowledge needed)

1. **Download:** only use the link you got directly from the person helping you. Click the green **Code** button on that repository page → **Download ZIP**. Open the ZIP file and choose **Extract all**.
   (Or clone it with git if you know how.)
2. **Double-click `Start PC Toolkit.cmd`.**
   - Click **Yes** when Windows asks whether to allow changes. You do not need to open PowerShell or "Run as administrator" yourself.
   - Windows may show a warning such as *"Windows protected your PC"*, *"Unknown publisher"* or *"Do you want to run this file?"*. **Do not click past it on your own.** See [If Windows shows a security warning](#if-windows-shows-a-security-warning) below.
   - The check takes 2–6 minutes and changes nothing. The report then opens in your web browser.
3. **In the report, go to *Fix problems*.** The recommended fixes are already ticked. Tick or untick what you want and click **Fix selected**.
   - Follow the progress on the page. When it is done you see what was fixed and what you need to do yourself.
   - Click **Restart now** if it is suggested, otherwise **Finish**.
   - **Keep the black PC Toolkit window open** until you are done. It closes by itself when you click Finish.
   - Want someone to look at the report first? Click **Finish** without fixing anything and send them the newest folder inside `Reports`. Start again later to fix things.

Tip: run the check when the computer feels slow, for example just after starting it.

## If Windows shows a security warning

Windows warns about files downloaded from the internet that are not digitally signed. These scripts are not signed, so the publisher is shown as *Unknown*. The toolkit never turns this protection off or removes the warning for you.

- **Stop** if you did not get the link directly from someone you trust, if the files came from another website, or if the warning names a different file than `Start PC Toolkit.cmd`.
- Otherwise, **call or message the person helping you before continuing**. They can confirm the files are theirs, or connect with **Quick Assist** (included with Windows) and start it together with you.
- The window where you click **Yes** to allow changes should say **Windows PowerShell** with the verified publisher **Microsoft Windows**. If it shows anything else, click **No**.

For helpers: the warning-free alternatives are to clone the repository with git (no download marking), copy the folder from a USB drive you prepared, or sign the scripts with a code-signing certificate before distributing them.

## What is in the folder

| | |
|---|---|
| `Start PC Toolkit.cmd` | The only file you need. Checks the computer, opens the report and lets you choose what to fix. |
| `Reports\` | Created automatically. One folder per check with the report, repair log and summary. |
| `scripts\` | The PowerShell scripts. Nothing in here needs to be opened. |

## What can be fixed

The *Fix problems* section in the report only offers what applies to this computer.

| Group | Actions |
|---|---|
| **Safety stop** | If a drive appears to be failing (or its health could not be checked), nothing can be fixed from the report. Back up important files first. |
| **Always first** | Creates a restore point and logs all actions in the report folder. If the restore point fails, nothing is changed. |
| **Recommended** (ticked) | Clean temporary files and the Windows Update cache; enable Storage Sense; switch from Power Saver to Balanced; enable/run TRIM for SSDs; update Defender and run a quick scan; repair Windows with DISM and SFC if the check found signs of problems; start Windows Update; re-enable the page file. |
| **Startup apps** | Every app that starts with Windows, with a suggestion (*Can be disabled*, *Optional*, *Unknown*, *Keep*). Only *Can be disabled* is ticked. |
| **Unwanted programs** (ticked) | Uninstall McAfee, Norton, “optimizers” and adware. The program's own uninstaller opens. |
| **Optional extras** | Empty the Recycle Bin, disable hibernation, full antivirus scan, defragment an HDD. |
| **Manual** | Upgrade to an SSD, replace a failing drive, enable XMP/EXPO in BIOS, upgrade RAM, remove dust, update the graphics driver, or perform an in-place repair install. These are listed in `repair-summary_*.txt`. |

The scripts do not use registry cleaners or disable Windows services.

## Undo

- **Startup apps:** Task Manager → Startup apps → right-click an app → Enable.
- **Other changes:** Search for “Create a restore point” → System Restore → select “PC Toolkit before repairs”.

## The report

`diagnostic-report.html` is a single self-contained file (no internet needed) with an overall verdict, a hardware overview, disk-space bars, findings sorted by severity (with whether they can be fixed from the report or need manual action), the *Fix problems* section and collapsible detail sections. Long lists have a filter box, **Expand all** opens everything, and printing expands all sections automatically. `diagnostic-report.json` contains the same data and is what `Repair.ps1` reads.

Opened directly from the `Reports` folder (for example by a helper), the report is read-only: fixes can only be started while PC Toolkit is running.

### How fixing from the browser works

After the check, the PC Toolkit window (which already has administrator permission) serves the report at `http://127.0.0.1:<random port>/<random secret>/` and opens it in the normal browser, which itself does **not** run as administrator. Clicking **Fix selected** sends the chosen options back to that window, which runs `Repair.ps1` in the background and shows its progress on the page.

- Only reachable from the same computer (127.0.0.1), never from the network.
- The address contains a random secret, and every request that changes something must repeat it in a header, so other websites cannot trigger repairs.
- Only option IDs that the report offered are accepted. Repairs are refused if drive health is uncertain.
- The server stops when you click Finish or Restart, when the window is closed, or after 30 minutes without activity.

## For helpers and developers

Advanced options, run from PowerShell in the toolkit folder:

```powershell
.\scripts\Diagnose.ps1 -DryRunRepairs       # Full flow, but fixes chosen in the browser are only simulated
.\scripts\Repair.ps1                        # Console version: asks questions instead of using the browser
.\scripts\Repair.ps1 -WhatIf                # Dry run: show what would happen
.\scripts\Repair.ps1 -AutomaticOnly         # Run automatic actions only; do not ask questions
.\scripts\Repair.ps1 -IgnoreDriveWarning    # Continue despite a drive warning (only after backing up)
.\scripts\Diagnose.ps1 -SkipUpdateCheck     # Faster check; do not search for Windows updates
```

### Testing without administrator permissions

Everything except the actual repairs can be verified on a computer where you are not an administrator:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Toolkit.ps1              # Full self-test, removes its reports
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Toolkit.ps1 -KeepReports # Keep the report to look at
```

The self-test checks that all scripts parse and the launchers point to existing scripts, runs `Diagnose.ps1 -NoElevation`, validates the JSON and HTML reports, runs `Repair.ps1 -WhatIf -AutomaticOnly` and verifies that nothing was changed, tests the fix page (`ReportServer.ps1 -DryRun`: secret, header check, option validation, a simulated repair and Finish), and checks that repairs are refused when a report indicates a failing drive.

To click through the browser flow without changing anything, run `.\scripts\Diagnose.ps1 -NoElevation -DryRunRepairs`. To try the console questions, run `.\scripts\Repair.ps1 -WhatIf`. Every change is printed as `What if: ...` instead of being performed. A dry run cannot prove that the real actions (restore point, DISM/SFC, uninstalling, TRIM) succeed; test those on a computer where you are an administrator.

## Helpful tools

- [CrystalDiskInfo](https://crystalmark.info/en/software/crystaldiskinfo/): drive health
- [HWiNFO](https://www.hwinfo.com/): temperatures
- Quick Assist (included with Windows): remote support
