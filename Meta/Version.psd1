# PoSh-Backup\Meta\Version.psd1
#
# Stores metadata about the currently installed version of PoSh-Backup.
# This file is updated when a new version is installed by the user or by the packager.
#
@{
    # --- Version & Build Information ---
    InstalledVersion         = "1.40.2"                           # The semantic version of the PoSh-Backup.ps1 script.
    CommitHash               = "N/A"                              # The short Git commit hash of this specific build for precise issue tracking.
    ReleaseDate              = "2025-07-05"                       # The official release date of this version (YYYY-MM-DD).

    # --- Update & Distribution Information ---
    DistributionType         = "ZipPackage"                       # How this version was likely distributed (e.g., "ZipPackage", "GitClone").
    UpdateChannel            = "Stable"                           # The update channel this installation tracks (e.g., "Stable", "Beta").
    LastUpdateCheckTimestamp = ""                                 # The ISO 8601 timestamp of when PoSh-Backup last checked for an update online.

    # --- Project Information ---
    ProjectUrl       = "https://github.com/BootBlock/PoSh-Backup" # The official project repository URL.
}
