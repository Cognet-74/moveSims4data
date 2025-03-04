<#
.SYNOPSIS
    Transfers Sims 4 user data from an old installation to a new installation safely.

.DESCRIPTION
    This script copies user-generated Sims 4 data (like saves, mods, tray files, screenshots, and optionally Options.ini)
    from a specified source directory (usually Documents\Electronic Arts\The Sims 4 from an old drive)
    to a destination directory (on your new computer). It avoids transferring system-specific files that could
    mess up your new installation (like Config.log, GameVersion.txt, cache files, or files in ConfigOverride).
    
    The script works by:
      - Skipping files that match default or user-specified blacklist patterns.
      - Comparing file metadata (size and last modification time) and computing file hashes (SHA256) if necessary.
      - Supporting a dry-run mode (using the -WhatIf switch) to simulate the operation without making any changes.
      - Optionally verifying that the directory structure matches between the source and destination.
      - Creating a backup of the destination folder before making changes (optional).
      - Supporting selective transfers of specific data types (saves, mods, etc.).
      - Providing progress reporting during the file transfer process.
      - Offering parallel processing for improved performance.

.PARAMETERS
    -SourcePath
        The full path of the old Sims 4 data folder (e.g., "E:\Documents\Electronic Arts\The Sims 4").
    -DestinationPath
        The full path of the new Sims 4 data folder (e.g., "C:\Users\<YourUsername>\Documents\Electronic Arts\The Sims 4").
    -Force
        (Switch) Overwrite existing files at the destination without prompting.
    -VerifyStructure
        (Switch) Verify that the directory structure and file locations match between source and destination.
    -Backup
        (Switch) Create a backup of the destination folder before making any changes.
    -LogFile
        (Optional) A file path to write logs to.
    -Blacklist
        (Optional) An array of wildcard patterns representing files or directories that should not be transferred.
        If not provided, a default list will be used to exclude system-specific files.
    -WhatIf
        (Switch) Simulate the file copy operation without making any changes (dry run).
    -TransferSaves
        (Switch) Transfer only save files.
    -TransferMods
        (Switch) Transfer only mod files.
    -TransferTray
        (Switch) Transfer only tray files (lots, households, Sims).
    -TransferScreenshots
        (Switch) Transfer only screenshot files.
    -TransferOptions
        (Switch) Transfer Options.ini file.
    -MaxParallelJobs
        (Optional) Maximum number of parallel file copy operations. Default is 4.

.EXAMPLE
    # Dry-run (simulate) the transfer, using the default blacklist:
    .\Move-Sims4Data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" `
        -DestinationPath "C:\Users\UserName\Documents\Electronic Arts\The Sims 4" `
        -Force -VerifyStructure -Verbose -WhatIf

.EXAMPLE
    # Transfer only mods and saves with backup:
    .\Move-Sims4Data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" `
        -DestinationPath "C:\Users\UserName\Documents\Electronic Arts\The Sims 4" `
        -TransferMods -TransferSaves -Backup -Force

.NOTES
    - Only user-generated data (saves, Tray, Mods, Screenshots, optionally Options.ini) is safe to transfer.
    - System-specific files (like Config.log, GameVersion.txt, cache files, and most ConfigOverride files)
      are excluded by default to protect the new computer's configuration.
    - Adjust the process name in the Check-SimsRunning function if needed.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,
    
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,
    
    [switch]$Force,
    
    [switch]$VerifyStructure,
    
    [switch]$Backup,
    
    [string]$LogFile,
    
    [string[]]$Blacklist,
    
    [switch]$WhatIf,
    
    [switch]$TransferSaves,
    
    [switch]$TransferMods,
    
    [switch]$TransferTray,
    
    [switch]$TransferScreenshots,
    
    [switch]$TransferOptions,
    
    [int]$MaxParallelJobs = 4
)

# Set default blacklist if user does not provide one.
# These patterns exclude files that are tied to the old system's configuration.
if (-not $Blacklist) {
    $Blacklist = @(
        "*Config.log*",
        "*GameVersion.txt*",
        "*localthumbcache.package*",
        "*avatarcache.package*",
        "*\ConfigOverride\*"
    )
}

# Stats tracking variables
$filesProcessed = 0
$filesSkipped = 0
$filesCopied = 0
$filesWithErrors = 0

# Function: Write-Log
# Writes a message to the console and appends it to a log file if provided.
function Write-Log {
    param (
        [string]$Message
    )
    Write-Output $Message
    if ($LogFile) {
        Add-Content -Path $LogFile -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message")
    }
}

# Function: Test-SimsRunning
# Checks if the Sims 4 process is running. Exits the script if it is.
function Test-SimsRunning {
    $processName = "TS4_x64"  # Change this if your Sims 4 process has a different name.
    if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
        Write-Log "Error: Sims 4 appears to be running. Please close the game and try again."
        exit 1
    }
}

# Function: Test-Blacklisted
# Checks if a given file (based on its relative path) matches any pattern in the blacklist.
function Test-Blacklisted {
    param (
        [string]$RelativePath,
        [string[]]$BlacklistPatterns
    )
    foreach ($pattern in $BlacklistPatterns) {
        if ($RelativePath -like $pattern) {
            return $true
        }
    }
    return $false
}

# Function: Backup-DestinationFolder
# Creates a backup of the destination folder if it exists.
function Backup-DestinationFolder {
    param (
        [string]$Path
    )
    
    if (Test-Path -Path $Path) {
        $backupFolder = "$Path-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Log "Creating backup of destination folder at: $backupFolder"
        
        if (-not $WhatIf) {
            Copy-Item -Path $Path -Destination $backupFolder -Recurse -Force
            Write-Log "Backup completed successfully."
        } else {
            Write-Log "Would create backup at: $backupFolder (WhatIf mode)"
        }
        return $backupFolder
    }
    Write-Log "No existing destination folder to backup."
    return $null
}

# Function: Invoke-SpecialFileHandler
# Performs special handling for different file types or common Sims 4 files.
function Invoke-SpecialFileHandler {
    param (
        [string]$FilePath
    )
    
    $extension = [System.IO.Path]::GetExtension($FilePath)
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    
    # Special handling for .package files
    if ($extension -eq ".package") {
        # Log size of package files
        $size = (Get-Item $FilePath).Length / 1MB
        Write-Log "Package file size: $([math]::Round($size, 2)) MB for $fileName"
    }
    
    # Special handling for Options.ini
    if ($fileName -eq "Options.ini") {
        Write-Log "Found Options.ini - ensure graphics settings match your new hardware"
        # Here you could potentially modify specific settings
    }
    
    # Special handling for save files
    if ($FilePath -like "*\Saves\*") {
        Write-Log "Transferred save file: $fileName"
    }
    
    # Special handling for mod files
    if ($FilePath -like "*\Mods\*") {
        if ($extension -eq ".ts4script") {
            Write-Log "Transferred script mod: $fileName"
        }
    }
}

# Begin Script Execution
Write-Log "Starting Sims 4 data transfer..."
Write-Log "Source: $SourcePath"
Write-Log "Destination: $DestinationPath"

# Ensure Sims 4 is not running.
Test-SimsRunning

# Verify that the source path exists.
if (-not (Test-Path -Path $SourcePath)) {
    Write-Log "Error: Source path '$SourcePath' does not exist."
    exit 1
}

# Verify or create the destination path.
if (-not (Test-Path -Path $DestinationPath)) {
    Write-Log "Destination path '$DestinationPath' does not exist. Creating directory..."
    try {
        if (-not $WhatIf) {
            New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
        } else {
            Write-Log "Would create destination directory: $DestinationPath (WhatIf mode)"
        }
    }
    catch {
        Write-Log "Error: Failed to create destination directory. $_"
        exit 1
    }
} elseif ($Backup) {
    # Create backup if requested and destination exists
    $backupLocation = Backup-DestinationFolder -Path $DestinationPath
    Write-Log "Backup location: $backupLocation"
}

Write-Log "Processing files from '$SourcePath'..."

# Get a list of all files in the source directory recursively.
$sourceFiles = Get-ChildItem -Path $SourcePath -Recurse -File

# Filter files based on selective transfer options if any are specified
if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions) {
    Write-Log "Applying selective transfer filters..."
    $inclusionPaths = @()
    
    if ($TransferSaves) { 
        $inclusionPaths += "*\Saves\*" 
        Write-Log "Including: Saves"
    }
    if ($TransferMods) { 
        $inclusionPaths += "*\Mods\*" 
        Write-Log "Including: Mods"
    }
    if ($TransferTray) { 
        $inclusionPaths += "*\Tray\*" 
        Write-Log "Including: Tray"
    }
    if ($TransferScreenshots) { 
        $inclusionPaths += "*\Screenshots\*" 
        Write-Log "Including: Screenshots"
    }
    if ($TransferOptions) { 
        $inclusionPaths += "*Options.ini*" 
        Write-Log "Including: Options.ini"
    }
    
    # Filter source files by inclusion paths
    $filteredFiles = @()
    foreach ($srcFile in $sourceFiles) {
        $relativePath = $srcFile.FullName.Substring($SourcePath.Length)
        foreach ($pattern in $inclusionPaths) {
            if ($relativePath -like $pattern) {
                $filteredFiles += $srcFile
                break
            }
        }
    }
    $sourceFiles = $filteredFiles
    Write-Log "Selected $($sourceFiles.Count) files for transfer based on filters."
}

$totalFiles = $sourceFiles.Count
Write-Log "Found $totalFiles files to process."

# Initialize parallel job array
$jobs = @()
$currentFile = 0

foreach ($srcFile in $sourceFiles) {
    $currentFile++
    $filesProcessed++
    
    # Show progress
    $percentComplete = [int](($currentFile / $totalFiles) * 100)
    Write-Progress -Activity "Transferring Sims 4 Files" -Status "Processing $currentFile of $totalFiles" -PercentComplete $percentComplete
    
    # Compute the file's relative path (so we can match against blacklist and build destination path).
    $relativePath = $srcFile.FullName.Substring($SourcePath.Length)
    # Build the full destination file path.
    $destFile = Join-Path $DestinationPath $relativePath

    # Skip this file if it matches any blacklist pattern.
    if (Test-Blacklisted -RelativePath $relativePath -BlacklistPatterns $Blacklist) {
        Write-Log "Skipping blacklisted file: $relativePath"
        $filesSkipped++
        continue
    }
    
    # Ensure the destination directory exists.
    $destDir = Split-Path $destFile -Parent
    if (-not (Test-Path -Path $destDir)) {
        try {
            if ($WhatIf) {
                Write-Log "Would create directory: $destDir"
            }
            else {
                New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                Write-Log "Created directory: $destDir"
            }
        }
        catch {
            Write-Log "Error creating directory '$destDir': $_"
            $filesWithErrors++
            continue
        }
    }
    
    # Decide if the file should be copied.
    $copyFile = $true

    # If the file exists in the destination, compare metadata and file hash.
    if (Test-Path -Path $destFile) {
        $destInfo = Get-Item -Path $destFile
        # First, compare file size and last write time.
        if (($srcFile.Length -eq $destInfo.Length) -and ($srcFile.LastWriteTime -eq $destInfo.LastWriteTime)) {
            # If metadata matches, compute hashes to confirm file content.
            $srcHash = (Get-FileHash -Path $srcFile.FullName -Algorithm SHA256).Hash
            $destHash = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash
            if ($srcHash -eq $destHash) {
                Write-Log "Skipping identical file: $relativePath (metadata and hash match)"
                $filesSkipped++
                $copyFile = $false
            }
            else {
                Write-Log "File $relativePath has matching metadata but different hash. Will copy file."
            }
        }
        else {
            # If metadata differs, still do a hash check.
            $srcHash = (Get-FileHash -Path $srcFile.FullName -Algorithm SHA256).Hash
            $destHash = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash
            if ($srcHash -eq $destHash) {
                Write-Log "Skipping file: $relativePath (hashes match despite metadata differences)"
                $filesSkipped++
                $copyFile = $false
            }
            else {
                Write-Log "File $relativePath differs (metadata or hash mismatch). Will copy file."
            }
        }
    }
    else {
        Write-Log "File $relativePath does not exist in destination. Will copy file."
    }

    # If file needs to be copied, perform the copy operation.
    if ($copyFile) {
        if ($WhatIf) {
            Write-Log "Would copy file: $relativePath (WhatIf mode)"
            $filesCopied++
        } else {
            # Use parallel jobs for file copying if not in WhatIf mode
            $job = Start-Job -ScriptBlock {
                param($src, $dest, $force)
                try {
                    if ($force) {
                        Copy-Item -Path $src -Destination $dest -Force
                    } else {
                        Copy-Item -Path $src -Destination $dest
                    }
                    return @{Success = $true; Path = $dest}
                } catch {
                    return @{Success = $false; Path = $dest; Error = $_.Exception.Message}
                }
            } -ArgumentList $srcFile.FullName, $destFile, $Force
            
            $jobs += @{Job = $job; RelativePath = $relativePath; DestFile = $destFile}
            
            # Wait if we've reached the max parallel jobs
            while ($jobs.Count -ge $MaxParallelJobs) {
                $completedJobs = @()
                foreach ($jobInfo in $jobs) {
                    if ($jobInfo.Job.State -ne "Running") {
                        $result = Receive-Job -Job $jobInfo.Job
                        if ($result.Success) {
                            Write-Log "Copied file: $($jobInfo.RelativePath)"
                            Invoke-SpecialFileHandler -FilePath $jobInfo.DestFile
                            $filesCopied++
                        } else {
                            Write-Log "Error copying file '$($jobInfo.RelativePath)': $($result.Error)"
                            $filesWithErrors++
                        }
                        Remove-Job -Job $jobInfo.Job
                        $completedJobs += $jobInfo
                    }
                }
                
                # Remove completed jobs from the tracking array
                foreach ($completed in $completedJobs) {
                    $jobs = $jobs | Where-Object { $_ -ne $completed }
                }
                
                if ($jobs.Count -ge $MaxParallelJobs) {
                    Start-Sleep -Milliseconds 100
                }
            }
        }
    }
}

# Wait for remaining jobs to complete
Write-Log "Waiting for remaining file copy operations to complete..."
while ($jobs.Count -gt 0) {
    $completedJobs = @()
    foreach ($jobInfo in $jobs) {
        if ($jobInfo.Job.State -ne "Running") {
            $result = Receive-Job -Job $jobInfo.Job
            if ($result.Success) {
                Write-Log "Copied file: $($jobInfo.RelativePath)"
                Invoke-SpecialFileHandler -FilePath $jobInfo.DestFile
                $filesCopied++
            } else {
                Write-Log "Error copying file '$($jobInfo.RelativePath)': $($result.Error)"
                $filesWithErrors++
            }
            Remove-Job -Job $jobInfo.Job
            $completedJobs += $jobInfo
        }
    }
    
    # Remove completed jobs from the tracking array
    foreach ($completed in $completedJobs) {
        $jobs = $jobs | Where-Object { $_ -ne $completed }
    }
    
    if ($jobs.Count -gt 0) {
        Start-Sleep -Milliseconds 100
    }
}

# Ensure progress bar is completed
Write-Progress -Activity "Transferring Sims 4 Files" -Status "Complete" -PercentComplete 100 -Completed

# Post-Copy: Verify by comparing file counts.
if (-not $WhatIf) {
    $finalSourceCount = (Get-ChildItem -Path $SourcePath -Recurse -File | 
        Where-Object { -not (Test-Blacklisted -RelativePath $_.FullName.Substring($SourcePath.Length) -BlacklistPatterns $Blacklist) }).Count
        
    $finalDestCount = (Get-ChildItem -Path $DestinationPath -Recurse -File).Count
    
    Write-Log "Post-Copy Verification: Source file count = $finalSourceCount, Destination file count = $finalDestCount."
    
    if ($finalSourceCount -ne $finalDestCount) {
        Write-Log "Warning: File count mismatch between source and destination."
    } else {
        Write-Log "File count verification successful."
    }
}

# Optional: Verify the overall directory structure if requested.
if ($VerifyStructure -and (-not $WhatIf)) {
    Write-Log "Verifying overall directory structure and file locations..."
    
    # Get lists of relative file paths for both source and destination.
    $sourceRelativeFiles = Get-ChildItem -Path $SourcePath -Recurse -File | 
        Where-Object { -not (Test-Blacklisted -RelativePath $_.FullName.Substring($SourcePath.Length) -BlacklistPatterns $Blacklist) } | 
        ForEach-Object { $_.FullName.Substring($SourcePath.Length) }
        
    $destRelativeFiles = Get-ChildItem -Path $DestinationPath -Recurse -File | ForEach-Object {
        $_.FullName.Substring($DestinationPath.Length)
    }
    
    $structureDifferences = Compare-Object -ReferenceObject $sourceRelativeFiles -DifferenceObject $destRelativeFiles
    if ($structureDifferences) {
        Write-Log "Directory structure discrepancies found:"
        $structureDifferences | ForEach-Object { Write-Log $_ }
    }
    else {
        Write-Log "Directory structure and file locations match exactly."
    }
}

# Generate summary report
Write-Log "----------------------------------------------"
Write-Log "Transfer Summary:"
Write-Log "  Files processed: $filesProcessed"
Write-Log "  Files skipped (identical): $filesSkipped"
Write-Log "  Files copied: $filesCopied"
Write-Log "  Files with errors: $filesWithErrors"
Write-Log "----------------------------------------------"

Write-Log "Sims 4 data transfer complete. You may now launch Sims 4 on your new installation."