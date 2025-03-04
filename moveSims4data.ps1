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
      - Processing files as a stream to minimize memory usage.

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
    -BatchSize
        (Optional) Number of files to process in each batch. Default is 100.

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
    
    [int]$MaxParallelJobs = 4,
    
    [int]$BatchSize = 100
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
$totalFiles = 0

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

# Function: Test-ShouldInclude
# Determines if a file should be included in the transfer based on selective transfer options.
function Test-ShouldInclude {
    param (
        [string]$RelativePath
    )
    
    # If no selective transfer options are specified, include all files
    if (-not ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions)) {
        return $true
    }
    
    # Check if the file matches any of the selective transfer criteria
    if ($TransferSaves -and $RelativePath -like "*\Saves\*") { return $true }
    if ($TransferMods -and $RelativePath -like "*\Mods\*") { return $true }
    if ($TransferTray -and $RelativePath -like "*\Tray\*") { return $true }
    if ($TransferScreenshots -and $RelativePath -like "*\Screenshots\*") { return $true }
    if ($TransferOptions -and $RelativePath -like "*Options.ini*") { return $true }
    
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

# Function: Get-RelativePath
# Gets the relative path between two paths
function Get-RelativePath {
    param (
        [string]$Path,
        [string]$BasePath
    )
    try {
        return [System.IO.Path]::GetRelativePath($BasePath, $Path)
    }
    catch {
        # Fallback method if GetRelativePath fails
        if ($Path.StartsWith($BasePath, [StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $Path.Substring($BasePath.Length)
            if ($relativePath.StartsWith([IO.Path]::DirectorySeparatorChar) -or 
                $relativePath.StartsWith([IO.Path]::AltDirectorySeparatorChar)) {
                $relativePath = $relativePath.Substring(1)
            }
            return $relativePath
        }
        return $Path
    }
}

# Function: Start-FileBatchProcessing
# Processes a batch of files for transfer
function Start-FileBatchProcessing {
    param (
        [System.IO.FileInfo[]]$FileBatch,
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$BlacklistPatterns,
        [bool]$IsWhatIf,
        [bool]$UseForce
    )
    
    $batchJobs = @()
    
    foreach ($file in $FileBatch) {
        $script:filesProcessed++
        
        # Compute the file's relative path
        $relativePath = Get-RelativePath -Path $file.FullName -BasePath $SourceRoot

        
        
        # Skip this file if it matches any blacklist pattern
        if (Test-Blacklisted -RelativePath $relativePath -BlacklistPatterns $BlacklistPatterns) {
            Write-Log "Skipping blacklisted file: $relativePath"
            $script:filesSkipped++
            continue
        }
        
        # Skip this file if it doesn't match inclusion criteria
        if (-not (Test-ShouldInclude -RelativePath $relativePath)) {
            $script:filesSkipped++
            continue
        }
        
        # Build the full destination file path
        $destFile = Join-Path $DestinationRoot $relativePath
        
        # Ensure the destination directory exists
        $destDir = Split-Path $destFile -Parent
        if (-not (Test-Path -Path $destDir)) {
            try {
                if ($IsWhatIf) {
                    Write-Log "Would create directory: $destDir"
                }
                else {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                    Write-Log "Created directory: $destDir"
                }
            }
            catch {
                Write-Log "Error creating directory '$destDir': $_"
                $script:filesWithErrors++
                continue
            }
        }
        
        # Decide if the file should be copied
        $copyFile = $true
        
        # If the file exists in the destination, compare metadata and file hash
        if (Test-Path -Path $destFile) {
            $destInfo = Get-Item -Path $destFile
            # First, compare file size and last write time
            if (($file.Length -eq $destInfo.Length) -and ($file.LastWriteTime -eq $destInfo.LastWriteTime)) {
                # If metadata matches, compute hashes to confirm file content
                $srcHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
                $destHash = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash
                if ($srcHash -eq $destHash) {
                    Write-Log "Skipping identical file: $relativePath (metadata and hash match)"
                    $script:filesSkipped++
                    $copyFile = $false
                }
                else {
                    Write-Log "File $relativePath has matching metadata but different hash. Will copy file."
                }
            }
            else {
                # If metadata differs, still do a hash check
                $srcHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
                $destHash = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash
                if ($srcHash -eq $destHash) {
                    Write-Log "Skipping file: $relativePath (hashes match despite metadata differences)"
                    $script:filesSkipped++
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
        
        # If file needs to be copied, perform the copy operation
        if ($copyFile) {
            if ($IsWhatIf) {
                Write-Log "Would copy file: $relativePath (WhatIf mode)"
                $script:filesCopied++
            } else {
                # Start a background job for this file
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
                } -ArgumentList $file.FullName, $destFile, $UseForce
                
                $batchJobs += @{Job = $job; RelativePath = $relativePath; DestFile = $destFile}
            }
        }
    }
    
    return $batchJobs
}

# Function: Wait-ForCompletedJobs
# Waits for jobs to complete and processes their results
function Wait-ForCompletedJobs {
    param (
        [array]$Jobs,
        [bool]$WaitForAll = $false
    )
    
    $completedJobs = @()
    
    foreach ($jobInfo in $Jobs) {
        if ($jobInfo.Job.State -ne "Running" -or $WaitForAll) {
            if ($WaitForAll -and $jobInfo.Job.State -eq "Running") {
                $jobInfo.Job | Wait-Job | Out-Null
            }
            
            $result = Receive-Job -Job $jobInfo.Job
            if ($result.Success) {
                Write-Log "Copied file: $($jobInfo.RelativePath)"
                Invoke-SpecialFileHandler -FilePath $jobInfo.DestFile
                $script:filesCopied++
            } else {
                Write-Log "Error copying file '$($jobInfo.RelativePath)': $($result.Error)"
                $script:filesWithErrors++
            }
            Remove-Job -Job $jobInfo.Job
            $completedJobs += $jobInfo
        }
    }
    
    # Remove completed jobs from the tracking array
    $remainingJobs = @()
    foreach ($job in $Jobs) {
        if (-not $completedJobs.Contains($job)) {
            $remainingJobs += $job
        }
    }
    
    return $remainingJobs
}

# Function: Get-TotalFileCount
# Get the total number of files to be processed (for progress reporting)
function Get-TotalFileCount {
    param (
        [string]$Path,
        [string[]]$BlacklistPatterns
    )
    
    $count = 0
    
    # Count files matching the inclusion criteria
    $directories = @($Path)
    $i = 0
    
    # First, get all top-level directories to process
    if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots) {
        $directories = @()
        if ($TransferSaves) { $directories += Join-Path $Path "Saves" }
        if ($TransferMods) { $directories += Join-Path $Path "Mods" }
        if ($TransferTray) { $directories += Join-Path $Path "Tray" }
        if ($TransferScreenshots) { $directories += Join-Path $Path "Screenshots" }
    }
    
    # Add the Options.ini file separately if needed
    if ($TransferOptions) {
        $optionsFile = Join-Path $Path "Options.ini"
        if (Test-Path $optionsFile) {
            $count++
        }
    }
    
    # Process each directory
    while ($i -lt $directories.Count) {
        $dir = $directories[$i]
        $i++
        
        if (-not (Test-Path $dir)) {
            continue
        }
        
        # Get all files in this directory (non-recursive)
        $files = Get-ChildItem -Path $dir -File
        
        # Count files that aren't blacklisted
        foreach ($file in $files) {
            $relativePath = Get-RelativePath -Path $file.FullName -BasePath $Path
            if (-not (Test-Blacklisted -RelativePath $relativePath -BlacklistPatterns $BlacklistPatterns)) {
                $count++
            }
        }
        
        # Add subdirectories to the directories array
        $subdirs = Get-ChildItem -Path $dir -Directory
        $directories += $subdirs.FullName
    }
    
    return $count
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

# Log which data types will be transferred
if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions) {
    Write-Log "Selective transfer enabled. Including:"
    if ($TransferSaves) { Write-Log " - Saves" }
    if ($TransferMods) { Write-Log " - Mods" }
    if ($TransferTray) { Write-Log " - Tray" }
    if ($TransferScreenshots) { Write-Log " - Screenshots" }
    if ($TransferOptions) { Write-Log " - Options.ini" }
}

# Get an estimate of total files for progress reporting
# (This is more efficient than a full recursive scan)
$totalFiles = Get-TotalFileCount -Path $SourcePath -BlacklistPatterns $Blacklist
Write-Log "Estimated total files to process: $totalFiles"

# Create an array to track all active jobs
$activeJobs = @()

# Process the Options.ini file separately if required
if ($TransferOptions) {
    $optionsFile = Join-Path $SourcePath "Options.ini"
    if (Test-Path $optionsFile) {
        $optionsFileInfo = Get-Item $optionsFile
        $optionsBatch = @($optionsFileInfo)
        $optionsJobs = Start-FileBatchProcessing -FileBatch $optionsBatch -SourceRoot $SourcePath -DestinationRoot $DestinationPath -BlacklistPatterns $Blacklist -IsWhatIf $WhatIf -UseForce $Force
        $activeJobs += $optionsJobs
    }
}

# Define directories to process based on selected options
$directories = @()
if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots) {
    if ($TransferSaves) { $directories += Join-Path $SourcePath "Saves" }
    if ($TransferMods) { $directories += Join-Path $SourcePath "Mods" }
    if ($TransferTray) { $directories += Join-Path $SourcePath "Tray" }
    if ($TransferScreenshots) { $directories += Join-Path $SourcePath "Screenshots" }
} else {
    # If no specific options selected, process the whole directory
    $directories += $SourcePath
}

# Process each main directory using a streaming approach
foreach ($directory in $directories) {
    if (-not (Test-Path $directory)) {
        Write-Log "Directory not found, skipping: $directory"
        continue
    }
    
    Write-Log "Processing directory: $directory"
    
    # Use a queue to process directories without recursion
    $dirQueue = New-Object System.Collections.Queue
    $dirQueue.Enqueue($directory)
    
    while ($dirQueue.Count -gt 0) {
        $currentDir = $dirQueue.Dequeue()
        
        # Get files in current directory (non-recursive)
        $currentBatch = @()
        $files = Get-ChildItem -Path $currentDir -File
        
        # Add files to the current batch
        $currentBatch += $files
        
        # Process the batch if it's full or if we've exhausted files in this directory
        if ($currentBatch.Count -ge $BatchSize) {
            # Process this batch of files
            $newJobs = Start-FileBatchProcessing -FileBatch $currentBatch -SourceRoot $SourcePath -DestinationRoot $DestinationPath -BlacklistPatterns $Blacklist -IsWhatIf $WhatIf -UseForce $Force
            $activeJobs += $newJobs
            $currentBatch = @()
            
            # Update progress
            $percentComplete = [int](($filesProcessed / $totalFiles) * 100)
            Write-Progress -Activity "Transferring Sims 4 Files" -Status "Processing $filesProcessed of $totalFiles" -PercentComplete $percentComplete
            
            # Wait for jobs to complete if we've reached the max
            while ($activeJobs.Count -ge $MaxParallelJobs) {
                Start-Sleep -Milliseconds 100
                $activeJobs = Wait-ForCompletedJobs -Jobs $activeJobs
            }
        }
        
        # Queue subdirectories for processing
        $subDirs = Get-ChildItem -Path $currentDir -Directory
        foreach ($subDir in $subDirs) {
            $dirQueue.Enqueue($subDir.FullName)
        }
        
        # Process any remaining files in the batch
        if ($currentBatch.Count -gt 0) {
            $newJobs = Start-FileBatchProcessing -FileBatch $currentBatch -SourceRoot $SourcePath -DestinationRoot $DestinationPath -BlacklistPatterns $Blacklist -IsWhatIf $WhatIf -UseForce $Force
            $activeJobs += $newJobs
            
            # Update progress
            $percentComplete = [int](($filesProcessed / $totalFiles) * 100)
            Write-Progress -Activity "Transferring Sims 4 Files" -Status "Processing $filesProcessed of $totalFiles" -PercentComplete $percentComplete
        }
    }
}

# Wait for all remaining jobs to complete
Write-Log "Waiting for remaining file copy operations to complete..."
Wait-ForCompletedJobs -Jobs $activeJobs -WaitForAll $true

# Ensure progress bar is completed
Write-Progress -Activity "Transferring Sims 4 Files" -Status "Complete" -PercentComplete 100 -Completed

# Post-Copy: Verify by comparing file counts if not in WhatIf mode
if (-not $WhatIf) {
    Write-Log "Performing post-copy verification..."
    
    # Build include patterns based on selective transfer options
    $includePatterns = @()
    if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions) {
        if ($TransferSaves) { $includePatterns += "*\Saves\*" }
        if ($TransferMods) { $includePatterns += "*\Mods\*" }
        if ($TransferTray) { $includePatterns += "*\Tray\*" }
        if ($TransferScreenshots) { $includePatterns += "*\Screenshots\*" }
        if ($TransferOptions) { $includePatterns += "*Options.ini*" }
    }
    
    # Function to check if a file should be counted in verification
    function Test-ShouldCount {
        param (
            [string]$Path,
            [string[]]$IncludePatterns,
            [string[]]$ExcludePatterns
        )
        
        # If the file is blacklisted, don't count it
        if ((Test-Blacklisted -RelativePath $Path -BlacklistPatterns $ExcludePatterns)) {
            return $false
        }
        
        # If we have include patterns and the file doesn't match any, don't count it
        if ($IncludePatterns.Count -gt 0) {
            $shouldInclude = $false
            foreach ($pattern in $IncludePatterns) {
                if ($Path -like $pattern) {
                    $shouldInclude = $true
                    break
                }
            }
            return $shouldInclude
        }
        
        # Default case: count the file
        return $true
    }
    
    # Count source files
    $sourceCount = 0
    $sourceQueue = New-Object System.Collections.Queue
    $sourceQueue.Enqueue($SourcePath)
    
    while ($sourceQueue.Count -gt 0) {
        $dir = $sourceQueue.Dequeue()
        $files = Get-ChildItem -Path $dir -File
        
        foreach ($file in $files) {
            $relativePath = Get-RelativePath -Path $file.FullName -BasePath $SourcePath
            if (Test-ShouldCount -Path $relativePath -IncludePatterns $includePatterns -ExcludePatterns $Blacklist) {
                $sourceCount++
            }
        }
        
        $subDirs = Get-ChildItem -Path $dir -Directory
        foreach ($subDir in $subDirs) {
            $sourceQueue.Enqueue($subDir.FullName)
        }
    }
    
    # Count destination files
    $destCount = 0
    $destQueue = New-Object System.Collections.Queue
    $destQueue.Enqueue($DestinationPath)
    
    while ($destQueue.Count -gt 0) {
        $dir = $destQueue.Dequeue()
        $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue
        
        foreach ($file in $files) {
            $relativePath = Get-RelativePath -Path $file.FullName -BasePath $DestinationPath
            if (Test-ShouldCount -Path $relativePath -IncludePatterns $includePatterns -ExcludePatterns $Blacklist) {
                $destCount++
            }
        }
        
        $subDirs = Get-ChildItem -Path $dir -Directory -ErrorAction SilentlyContinue
        foreach ($subDir in $subDirs) {
            $destQueue.Enqueue($subDir.FullName)
        }
    }
    
    Write-Log "Post-Copy Verification: Source file count = $sourceCount, Destination file count = $destCount."
    
    if ($sourceCount -ne $destCount) {
        Write-Log "Warning: File count mismatch between source and destination."
    } else {
        Write-Log "File count verification successful."
    }
}

# Optional: Verify the overall directory structure if requested
if ($VerifyStructure -and (-not $WhatIf)) {
    Write-Log "Verifying overall directory structure and file locations..."
    
    # Build include patterns based on selective transfer options
    $includePatterns = @()
    if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions) {
        if ($TransferSaves) { $includePatterns += "*\Saves\*" }
        if ($TransferMods) { $includePatterns += "*\Mods\*" }
        if ($TransferTray) { $includePatterns += "*\Tray\*" }
        if ($TransferScreenshots) { $includePatterns += "*\Screenshots\*" }
        if ($TransferOptions) { $includePatterns += "*Options.ini*" }
    }
    
    # Get source relative paths
    $sourceRelativePaths = @()
    $sourceQueue = New-Object System.Collections.Queue
    $sourceQueue.Enqueue($SourcePath)
    
    while ($sourceQueue.Count -gt 0) {
        $dir = $sourceQueue.Dequeue()
        $files = Get-ChildItem -Path $dir -File
        
        foreach ($file in $files) {
            $relativePath = Get-RelativePath -Path $file.FullName -BasePath $SourcePath
            if (Test-ShouldCount -Path $relativePath -IncludePatterns $includePatterns -ExcludePatterns $Blacklist) {
                $sourceRelativePaths += $relativePath
            }
        }
        
        $subDirs = Get-ChildItem -Path $dir -Directory
        foreach ($subDir in $subDirs) {
            $sourceQueue.Enqueue($subDir.FullName)
        }
    }
    
    # Get destination relative paths
    $destRelativePaths = @()
    $destQueue = New-Object System.Collections.Queue
    $destQueue.Enqueue($DestinationPath)

    while ($destQueue.Count -gt 0) {
        $dir = $destQueue.Dequeue()
        $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue
        
        foreach ($file in $files) {
            $relativePath = [System.IO.Path]::GetRelativePath($DestinationPath, $file.FullName)
            if (Test-ShouldCount -Path $relativePath -IncludePatterns $includePatterns -ExcludePatterns $Blacklist) {
                $destRelativePaths += $relativePath
            }
        }
        
        $subDirs = Get-ChildItem -Path $dir -Directory -ErrorAction SilentlyContinue
        foreach ($subDir in $subDirs) {
            $destQueue.Enqueue($subDir.FullName)
        }
    }

    # Compare source and destination paths
    $missingFiles = $sourceRelativePaths | Where-Object { $_ -notin $destRelativePaths }
    $extraFiles = $destRelativePaths | Where-Object { $_ -notin $sourceRelativePaths }

    if ($missingFiles) {
        Write-Log "Warning: The following files are missing from destination:"
        $missingFiles | ForEach-Object { Write-Log "  $_" }
    }

    if ($extraFiles) {
        Write-Log "Warning: The following extra files were found in destination:"
        $extraFiles | ForEach-Object { Write-Log "  $_" }
    }

    if (-not $missingFiles -and -not $extraFiles) {
        Write-Log "Directory structure verification successful."
    }
}