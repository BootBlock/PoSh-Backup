# PoSh-Backup\Meta\Version.psd1
#
# Stores metadata about the currently installed version of PoSh-Backup.
# This file is updated when a new version is installed by the user or by the packager.
#
@{
    InstalledVersion = "1.36.0"                                     # Current version of PoSh-Backup.ps1
    ReleaseDate      = "2025-06-26"                                 # Release date of this version (YYYY-MM-DD)
    ProjectUrl       = "https://github.com/BootBlock/PoSh-Backup"   # Where PoSh Backup lives, innit.
    UpdateStrategy   = "ReplaceFolder"                              # Default strategy the apply_update.ps1 might use. Temporary, unused.
    DistributionType = "ZipPackage"                                 # How this version was likely distributed (e.g., "ZipPackage", "GitClone")
                                                                    # This might inform future update strategies.
}
