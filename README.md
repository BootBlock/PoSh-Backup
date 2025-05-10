# PoSh-Backup
A powerful PowerShell script for backing up your files that uses the free [7-Zip](https://www.7-zip.org/) compression software.

Key features include:
- **Modular design:** Main script, Utils module, Operations module (including Invoke-PoShBackupJob).
- **External `.psd1` configuration:** Global, per-job, and backup set definitions.
- **Backup Sets:** Group multiple backup jobs to run sequentially with `-RunSet`.
- **Volume Shadow Copy Service (VSS):** For backing up open/locked files (requires Admin). Configurable context options.
- **Retry Mechanism:** For 7-Zip operations on transient failures.
- **7-Zip options:** Control various aspects of 7-Zip itself.
- **Pre-job and Post-job Script Hooks:** For custom automation actions.
- **Detailed HTML Reports:** Summarising backup operations with modern styling.
- **Configuration Test Mode:** Validate .psd1 configuration with `-TestConfig`.
- Extensive logging, simulate mode, free space checks, archive testing, and more.
