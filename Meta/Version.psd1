# PoSh-Backup\Meta\Version.psd1
#
# Stores metadata about the currently installed version of PoSh-Backup.
# This file is updated when a new version is installed or by the packager.
#
@{
    InstalledVersion = "1.14.6"    # Current version of PoSh-Backup.ps1
    ReleaseDate      = "2025-05-31" # Release date of this version (YYYY-MM-DD)
    ProjectUrl       = "https://github.com/BootBlock/PoSh-Backup" # Where PoSh Backup lives, innit.
    DistributionType = "Zip"        # How this version was likely distributed (e.g., "Zip", "GitClone")
                                    # This might inform future update strategies.
    UpdateStrategy   = "ReplaceFolder" # Default strategy the apply_update.ps1 might use. Temporary, unused.
}
