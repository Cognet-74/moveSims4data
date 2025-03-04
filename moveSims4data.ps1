<#
.SYNOPSIS
    Transfers Sims 4 user data from an old installation to a new installation safely with optimized memory usage.

.DESCRIPTION
    This script copies user-generated Sims 4 data (like saves, mods, tray files, screenshots, and optionally Options.ini)
    from a specified source directory (usually Documents\Electronic Arts\The Sims 4 from an old drive)
    to a destination directory (on your new computer). It avoids transferring system-specific files that could
    mess up your new installation (like Config.log, GameVersion.txt, cache files, or files in ConfigOverride).
    
    The script has been optimized to handle large file transfers (18,000+ files) with minimal memory usage.
    
    The script works by:
      - Using a streaming approach to process files in small batches
      - Skipping files that match default or user-specified blacklist patterns
      - Comparing file metadata (size and last modification time) and computing file hashes (SHA256) if necessary
      - Supporting a dry-run mode (using the -WhatIf switch) to simulate the operation without making any changes
      - Optionally verifying that the directory structure matches between the source and destination
      - Creating a backup of the destination folder before making changes (optional)
      - Supporting selective transfers of specific data types (saves, mods, etc.)
      - Providing progress reporting during the file transfer process
      - Offering parallel processing for improved performance
      - Processing files as a stream to minimize memory usage
      - Using aggressive garbage collection to prevent memory bloat

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
        For large transfers, this will be automatically reduced to conserve memory.

.EXAMPLE
    # Dry-run (simulate) the transfer, using the default blacklist:
    .\moveSims4data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" `
        -DestinationPath "C:\Users\UserName\Documents\Electronic Arts\The Sims 4" `
        -Force -VerifyStructure -Verbose -WhatIf

.EXAMPLE
    # Transfer only mods and saves with backup:
    .\moveSims4data.ps1 -SourcePath "E:\Documents\Electronic Arts\The Sims 4" `
        -DestinationPath "C:\Users\UserName\Documents\Electronic Arts\The Sims 4" `
        -TransferMods -TransferSaves -Backup -Force

.NOTES
    - Only user-generated data (saves, Tray, Mods, Screenshots, optionally Options.ini) is safe to transfer.
    - System-specific files (like Config.log, GameVersion.txt, cache files, and most ConfigOverride files)
      are excluded by default to protect the new computer's configuration.
    - Adjust the process name in the Check-SimsRunning function if needed.
    - This script is optimized for memory efficiency when handling large file sets.
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

#region Helper Functions

# Function: Write-Log
# Writes a message to the console and appends it to a log file if provided.
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Critical')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $formattedMessage = "$timestamp - [$Level] $Message"
    
    # Output to console with appropriate coloring
    switch ($Level) {
        'Warning' { Write-Host $formattedMessage -ForegroundColor Yellow }
        'Error' { Write-Host $formattedMessage -ForegroundColor Red }
        'Critical' { Write-Host $formattedMessage -ForegroundColor Red -BackgroundColor Black }
        default { Write-Host $formattedMessage }
    }
    
    # Write to log file if specified
    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $formattedMessage -ErrorAction Stop
        }
        catch {
            # If unable to write to log file, output to console
            Write-Host "Failed to write to log file: $_" -ForegroundColor Red
        }
    }
}

# Function: Convert-PathFormat
# Normalizes a path to use consistent separators and formats
function Convert-PathFormat {
    param (
        [string]$Path
    )
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    
    # Replace forward slashes with backslashes
    $normalizedPath = $Path.Replace('/', '\')
    
    # Remove trailing backslash if present (except for root drives)
    if ($normalizedPath.EndsWith('\') -and -not ($normalizedPath -match '^[A-Za-z]:\\$')) {
        $normalizedPath = $normalizedPath.Substring(0, $normalizedPath.Length - 1)
    }
    
    return $normalizedPath
}

# Function: Join-PathSafely
# Safely joins path components with proper error handling
function Join-PathSafely {
    param (
        [string]$Path,
        [string]$ChildPath
    )
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Log "Base path is empty in Join-PathSafely." -Level Warning
        return $ChildPath
    }
    
    if ([string]::IsNullOrWhiteSpace($ChildPath)) {
        Write-Log "Child path is empty in Join-PathSafely." -Level Warning
        return $Path
    }
    
    # Normalize paths to use backslashes
    $normalizedPath = $Path.Replace('/', '\')
    $normalizedChildPath = $ChildPath.Replace('/', '\')
    
    # Remove trailing backslash from base path if present
    if ($normalizedPath.EndsWith('\')) {
        $normalizedPath = $normalizedPath.Substring(0, $normalizedPath.Length - 1)
    }
    
    # Remove leading backslash from child path if present
    if ($normalizedChildPath.StartsWith('\')) {
        $normalizedChildPath = $normalizedChildPath.Substring(1)
    }
    
    return "$normalizedPath\$normalizedChildPath"
}

# Function: Test-PathAndLog
# Checks if a path exists and logs the result
function Test-PathAndLog {
    param (
        [string]$Path,
        [string]$Description,
        [switch]$Critical
    )
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Log "Attempted to check an empty path for '$Description'." -Level Error
        if ($Critical) { return $false }
        return $false
    }
    
    $exists = Test-Path -Path $Path
    if (-not $exists) {
        $message = "Path for '$Description' does not exist: $Path"
        if ($Critical) {
            Write-Log $message -Level Critical
            return $false
        }
        else {
            Write-Log $message -Level Warning
            return $false
        }
    }
    return $true
}

# Function: New-DirectorySafely
# Creates a directory with better error handling and race condition prevention
function New-DirectorySafely {
    param (
        [string]$Path,
        [bool]$IsWhatIf
    )
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Log "Attempted to create a directory with an empty path." -Level Error
        return $false
    }
    
    if (Test-Path -Path $Path) {
        # Directory already exists
        return $true
    }
    
    if ($IsWhatIf) {
        Write-Log "Would create directory: $Path (WhatIf mode)"
        return $true
    }
    
    try {
        # Create parent directories if needed
        $parentDir = Split-Path -Path $Path -Parent
        if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -Path $parentDir)) {
            New-DirectorySafely -Path $parentDir -IsWhatIf $IsWhatIf | Out-Null
        }
        
        # Use try-catch to handle race conditions where another thread might have created the directory
        try {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Created directory: $Path"
            return $true
        }
        catch [System.IO.IOException] {
            # Check if the directory was created by another thread
            if (Test-Path -Path $Path) {
                return $true
            }
            throw
        }
    }
    catch {
        Write-Log "Error creating directory '$Path': $_" -Level Error
        return $false
    }
}

# Function: Get-RelativePath
# Gets the relative path between two paths with improved error handling
function Get-RelativePath {
    param (
        [string]$BasePath,
        [string]$FullPath
    )

    # Check if FullPath or BasePath is empty or null
    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        Write-Log "FullPath parameter is empty or null. Cannot compute relative path." -Level Warning
        return ""
    }
    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        Write-Log "BasePath parameter is empty or null. Cannot compute relative path." -Level Warning
        return ""
    }

    # Normalize paths to ensure consistent directory separators
    $normalizedBasePath = Convert-PathFormat -Path $BasePath
    $normalizedFullPath = Convert-PathFormat -Path $FullPath

    # Try using Resolve-Path but handle non-existent paths too
    try {
        if (Test-Path $normalizedBasePath) {
            $basePath = (Resolve-Path $normalizedBasePath).Path
        } else {
            $basePath = $normalizedBasePath
        }

        if (Test-Path $normalizedFullPath) {
            $fullPath = (Resolve-Path $normalizedFullPath).Path
        } else {
            $fullPath = $normalizedFullPath
        }
    }
    catch {
        Write-Log "Error resolving paths: $_" -Level Warning
        return ""
    }

    # Ensure the base path ends with a directory separator
    if (-not $basePath.EndsWith('\')) {
        $basePath += '\'
    }

    # Handle case where full path isn't under base path
    if (-not $fullPath.StartsWith($basePath, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "'$fullPath' is not under '$basePath', cannot compute relative path." -Level Warning
        return ""
    }

    # Get the relative path by removing the base path
    $relativePath = $fullPath.Substring($basePath.Length)
    
    # Remove leading separator if present
    if ($relativePath.StartsWith('\')) {
        $relativePath = $relativePath.Substring(1)
    }
    
    return $relativePath
}

# Function: Test-SimsRunning
# Checks if the Sims 4 process is running. Exits the script if it is.
function Test-SimsRunning {
    $processName = "TS4_x64"  # Change this if your Sims 4 process has a different name.
    if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
        Write-Log "Sims 4 appears to be running. Please close the game and try again." -Level Critical
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
    
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        Write-Log "Empty relative path provided to Test-Blacklisted." -Level Warning
        return $true  # Safer to skip files with empty paths
    }
    
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
    
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        Write-Log "Empty relative path provided to Test-ShouldInclude." -Level Warning
        return $false  # Safer to skip files with empty paths
    }
    
    # Normalize the path for consistent comparisons
    $normalizedPath = Convert-PathFormat -Path $RelativePath
    
    # If no selective transfer options are specified, include all files
    if (-not ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions)) {
        return $true
    }
    
    # Check if the file matches any of the selective transfer criteria
    if ($TransferSaves -and $normalizedPath -like "*\Saves\*") { return $true }
    if ($TransferMods -and $normalizedPath -like "*\Mods\*") { return $true }
    if ($TransferTray -and $normalizedPath -like "*\Tray\*") { return $true }
    if ($TransferScreenshots -and $normalizedPath -like "*\Screenshots\*") { return $true }
    if ($TransferOptions -and $normalizedPath -like "*Options.ini*") { return $true }
    
    return $false
}

# Function: Test-ShouldCount
# Checks if a file should be counted in verification based on include/exclude patterns
function Test-ShouldCount {
    param (
        [string]$Path,
        [string[]]$IncludePatterns,
        [string[]]$ExcludePatterns
    )
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Log "Empty path provided to Test-ShouldCount." -Level Warning
        return $false  # Safer to skip files with empty paths
    }
    
    # Normalize the path for consistent comparisons
    $normalizedPath = Convert-PathFormat -Path $Path
    
    # If the file is blacklisted, don't count it
    if ((Test-Blacklisted -RelativePath $normalizedPath -BlacklistPatterns $ExcludePatterns)) {
        return $false
    }
    
    # If we have include patterns and the file doesn't match any, don't count it
    if ($IncludePatterns.Count -gt 0) {
        $shouldInclude = $false
        foreach ($pattern in $IncludePatterns) {
            if ($normalizedPath -like $pattern) {
                $shouldInclude = $true
                break
            }
        }
        return $shouldInclude
    }
    
    # Default case: count the file
    return $true
}

# Function: Backup-DestinationFolder
# Creates a backup of the destination folder if it exists.
function Backup-DestinationFolder {
    param (
        [string]$Path
    )
    
    $normalizedPath = Convert-PathFormat -Path $Path
    
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        Write-Log "Empty path provided to Backup-DestinationFolder." -Level Error
        return $null
    }
    
    if (Test-Path -Path $normalizedPath) {
        $backupFolder = "$normalizedPath-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Log "Creating backup of destination folder at: $backupFolder"
        
        if (-not $WhatIf) {
            try {
                # Use robocopy for more efficient backups of large directories
                if ((Get-Command robocopy -ErrorAction SilentlyContinue)) {
                    # Create the target directory
                    New-Item -Path $backupFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    
                    # Use robocopy with /MIR to mirror the directory
                    # /MT for multithreaded copies, /NFL for no file list, /NDL for no directory list, /NJH no job header
                    $result = Start-Process -FilePath "robocopy.exe" -ArgumentList "`"$normalizedPath`" `"$backupFolder`" /E /MIR /MT:8 /NFL /NDL /NJH /NJS" -NoNewWindow -Wait -PassThru
                    
                    # Robocopy returns non-zero exit codes for successful operations
                    if ($result.ExitCode -ge 8) {
                        Write-Log "Robocopy reported errors during backup (exit code $($result.ExitCode)). Falling back to PowerShell copy." -Level Warning
                        Copy-Item -Path $normalizedPath -Destination $backupFolder -Recurse -Force -ErrorAction Stop
                    }
                    else {
                        Write-Log "Backup completed successfully using robocopy."
                    }
                }
                else {
                    # Fallback to PowerShell's Copy-Item
                    Copy-Item -Path $normalizedPath -Destination $backupFolder -Recurse -Force -ErrorAction Stop
                    Write-Log "Backup completed successfully using PowerShell copy."
                }
            }
            catch {
                Write-Log "Failed to create backup: $_" -Level Error
                return $null
            }
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
    
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        Write-Log "Empty path provided to Invoke-SpecialFileHandler." -Level Warning
        return
    }
    
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        Write-Log "File not found for special handling: $FilePath" -Level Warning
        return
    }
    
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

# New helper function for efficient file count
function Get-DirectoryFileCount {
    param (
        [string]$Directory,
        [string]$RootPath,
        [string[]]$IncludePatterns,
        [string[]]$ExcludePatterns
    )
    
    $count = 0
    
    # Use a stack instead of a queue to reduce memory pressure
    $dirStack = New-Object System.Collections.Generic.Stack[string]
    $dirStack.Push($Directory)
    
    while ($dirStack.Count -gt 0) {
        $currentDir = $dirStack.Pop()
        
        if (-not (Test-Path -Path $currentDir -PathType Container)) {
            continue
        }
        
        try {
            # Get files in chunks to avoid loading too many at once
            Get-ChildItem -Path $currentDir -File -ErrorAction Stop | ForEach-Object {
                $file = $_
                if ($null -eq $file) { return }
                
                if ([string]::IsNullOrWhiteSpace($file.FullName)) { return }
                
                $relativePath = Get-RelativePath -BasePath $RootPath -FullPath $file.FullName
                if ([string]::IsNullOrWhiteSpace($relativePath)) { return }
                
                if (Test-ShouldCount -Path $relativePath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns) {
                    $count++
                }
                
                # Clear variable to help with garbage collection
                $file = $null
            }
            
            # Add subdirectories to the stack
            Get-ChildItem -Path $currentDir -Directory -ErrorAction Stop | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.FullName)) {
                    $dirStack.Push($_.FullName)
                }
            }
        }
        catch {
            Write-Log "Error processing directory '$currentDir': $_. Skipping directory." -Level Error
        }
    }
    
    return $count
}

# Optimized version of Get-TotalFileCount
function Get-TotalFileCount {
    param (
        [string]$Path,
        [string[]]$BlacklistPatterns
    )
    
    $normalizedPath = Convert-PathFormat -Path $Path
    
    if (-not (Test-Path -Path $normalizedPath)) {
        Write-Log "Path does not exist: $normalizedPath" -Level Warning
        return 0
    }
    
    $count = 0
    
    # Create include patterns based on selective transfer options
    $includePatterns = @()
    if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions) {
        if ($TransferSaves) { $includePatterns += "*\Saves\*" }
        if ($TransferMods) { $includePatterns += "*\Mods\*" }
        if ($TransferTray) { $includePatterns += "*\Tray\*" }
        if ($TransferScreenshots) { $includePatterns += "*\Screenshots\*" }
        if ($TransferOptions) { $includePatterns += "*Options.ini*" }
    }
    
    # Process selectively by directory to reduce memory usage
    if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots) {
        # Only process selected directories
        if ($TransferSaves) { 
            $savesDir = Join-PathSafely -Path $normalizedPath -ChildPath "Saves"
            if (Test-Path -Path $savesDir) {
                $count += Get-DirectoryFileCount -Directory $savesDir -RootPath $normalizedPath -IncludePatterns $includePatterns -ExcludePatterns $BlacklistPatterns
            }
        }
        if ($TransferMods) { 
            $modsDir = Join-PathSafely -Path $normalizedPath -ChildPath "Mods"
            if (Test-Path -Path $modsDir) {
                $count += Get-DirectoryFileCount -Directory $modsDir -RootPath $normalizedPath -IncludePatterns $includePatterns -ExcludePatterns $BlacklistPatterns
            }
        }
        if ($TransferTray) { 
            $trayDir = Join-PathSafely -Path $normalizedPath -ChildPath "Tray"
            if (Test-Path -Path $trayDir) {
                $count += Get-DirectoryFileCount -Directory $trayDir -RootPath $normalizedPath -IncludePatterns $includePatterns -ExcludePatterns $BlacklistPatterns
            }
        }
        if ($TransferScreenshots) { 
            $screenshotsDir = Join-PathSafely -Path $normalizedPath -ChildPath "Screenshots"
            if (Test-Path -Path $screenshotsDir) {
                $count += Get-DirectoryFileCount -Directory $screenshotsDir -RootPath $normalizedPath -IncludePatterns $includePatterns -ExcludePatterns $BlacklistPatterns
            }
        }
    } else {
        # Process everything
        $count += Get-DirectoryFileCount -Directory $normalizedPath -RootPath $normalizedPath -IncludePatterns $includePatterns -ExcludePatterns $BlacklistPatterns
    }
    
    # Add the Options.ini file separately if needed
    if ($TransferOptions) {
        $optionsFile = Join-PathSafely -Path $normalizedPath -ChildPath "Options.ini"
        if (Test-Path $optionsFile) {
            $count++
        }
    }
    
    return $count
}

# Modified Start-DirectoryProcessing function
function Start-DirectoryProcessing {
    param (
        [string]$Directory,
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$BlacklistPatterns,
        [bool]$IsWhatIf,
        [bool]$UseForce,
        [int]$BatchSize,
        [ref]$ActiveJobsRef,
        [int]$MaxParallelJobs
    )
    
    if (-not (Test-PathAndLog -Path $Directory -Description "Directory to process")) {
        return
    }
    
    $normalizedDirectory = Convert-PathFormat -Path $Directory
    $normalizedSourceRoot = Convert-PathFormat -Path $SourceRoot
    $normalizedDestinationRoot = Convert-PathFormat -Path $DestinationRoot
    
    Write-Log "Processing directory: $normalizedDirectory"
    
    # Use a stack instead of a queue for better memory management
    $dirStack = New-Object System.Collections.Generic.Stack[string]
    $dirStack.Push($normalizedDirectory)
    
    # Reduce batch size for large transfers
    $effectiveBatchSize = [Math]::Min($BatchSize, 20)
    
    while ($dirStack.Count -gt 0) {
        $currentDir = $dirStack.Pop()
        
        if (-not (Test-Path -Path $currentDir -PathType Container)) {
            Write-Log "Directory no longer exists: $currentDir. Skipping." -Level Warning
            continue
        }
        
        # Get files in current directory - process them in smaller batches
        $batchCount = 0
        $currentBatch = @()
        
        try {
            # Process files in smaller chunks
            Get-ChildItem -Path $currentDir -File -ErrorAction Stop | ForEach-Object {
                $file = $_
                
                # Add file to current batch
                $currentBatch += $file
                $batchCount++
                
                # Process batch if it's reached the size limit
                if ($batchCount -ge $effectiveBatchSize) {
                    # Process this batch of files
                    $newJobs = Start-FileBatchProcessing -FileBatch $currentBatch -SourceRoot $normalizedSourceRoot -DestinationRoot $normalizedDestinationRoot -BlacklistPatterns $BlacklistPatterns -IsWhatIf $IsWhatIf -UseForce $UseForce
                    
                    # Use batched job processing
                    Start-BatchedJobs -Jobs $newJobs -ActiveJobsRef $ActiveJobsRef -MaxJobs $MaxParallelJobs
                    
                    # Clear the batch array to free memory
                    $currentBatch = @()
                    $batchCount = 0
                    
                    # Update progress
                    $percentComplete = if ($script:totalFiles -gt 0) { [int](($script:filesProcessed / $script:totalFiles) * 100) } else { 0 }
                    Write-Progress -Activity "Transferring Sims 4 Files" -Status "Processing $($script:filesProcessed) of $($script:totalFiles)" -PercentComplete $percentComplete
                }
            }
            
            # Process any remaining files in the batch
            if ($currentBatch.Count -gt 0) {
                $newJobs = Start-FileBatchProcessing -FileBatch $currentBatch -SourceRoot $normalizedSourceRoot -DestinationRoot $normalizedDestinationRoot -BlacklistPatterns $BlacklistPatterns -IsWhatIf $IsWhatIf -UseForce $UseForce
                
                # Use batched job processing
                Start-BatchedJobs -Jobs $newJobs -ActiveJobsRef $ActiveJobsRef -MaxJobs $MaxParallelJobs
                
                # Clear the batch array to free memory
                $currentBatch = @()
                
                # Update progress
                $percentComplete = if ($script:totalFiles -gt 0) { [int](($script:filesProcessed / $script:totalFiles) * 100) } else { 0 }
                Write-Progress -Activity "Transferring Sims 4 Files" -Status "Processing $($script:filesProcessed) of $($script:totalFiles)" -PercentComplete $percentComplete
            }
            
            # Queue subdirectories for processing - do after processing files to reduce memory usage
            Get-ChildItem -Path $currentDir -Directory -ErrorAction Stop | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.FullName)) {
                    $dirStack.Push($_.FullName)
                }
            }
            
            # Force garbage collection between directories to free memory
            [System.GC]::Collect()
        }
        catch {
            Write-Log "Error processing directory '$currentDir': $_. Skipping directory." -Level Error
        }
    }
}

# Function to compare directory structures efficiently
function Compare-DirectoryStructures {
    param (
        [string]$SourcePath,
        [string]$DestinationPath,
        [string[]]$IncludePatterns,
        [string[]]$ExcludePatterns,
        [bool]$IsWhatIf
    )
    
    $normalizedSourcePath = Convert-PathFormat -Path $SourcePath
    $normalizedDestinationPath = Convert-PathFormat -Path $DestinationPath
    
    if (-not (Test-Path -Path $normalizedSourcePath)) {
        Write-Log "Source path does not exist: $normalizedSourcePath" -Level Error
        return
    }
    
    if (-not (Test-Path -Path $normalizedDestinationPath) -and -not $IsWhatIf) {
        Write-Log "Destination path does not exist: $normalizedDestinationPath" -Level Error
        return
    }
    
    # Skip destination comparison in WhatIf mode
    if ($IsWhatIf) {
        Write-Log "Skipping destination structure verification in WhatIf mode."
        return
    }
    
    Write-Log "Comparing directory structures (this may take some time for large directories)..."
    
    # Use more memory-efficient approach by comparing files one by one
    $missingFiles = New-Object System.Collections.ArrayList
    $extraFiles = New-Object System.Collections.ArrayList
    
    # Process source files using a stack-based approach
    $sourceStack = New-Object System.Collections.Generic.Stack[string]
    $sourceStack.Push($normalizedSourcePath)
    
    while ($sourceStack.Count -gt 0) {
        $currentDir = $sourceStack.Pop()
        
        if (-not (Test-Path -Path $currentDir -PathType Container)) {
            continue
        }
        
        # Process files in the current directory
        Get-ChildItem -Path $currentDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_
            $relativePath = Get-RelativePath -BasePath $normalizedSourcePath -FullPath $file.FullName
            
            if ([string]::IsNullOrEmpty($relativePath)) { return }
            
            if (Test-ShouldCount -Path $relativePath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns) {
                $destFilePath = Join-PathSafely -Path $normalizedDestinationPath -ChildPath $relativePath
                
                if (-not (Test-Path -Path $destFilePath -PathType Leaf)) {
                    [void]$missingFiles.Add($relativePath)
                }
            }
        }
        
        # Queue subdirectories for processing
        Get-ChildItem -Path $currentDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $sourceStack.Push($_.FullName)
        }
    }
    
    # Process destination files to find extras
    $destStack = New-Object System.Collections.Generic.Stack[string]
    $destStack.Push($normalizedDestinationPath)
    
    while ($destStack.Count -gt 0) {
        $currentDir = $destStack.Pop()
        
        if (-not (Test-Path -Path $currentDir -PathType Container)) {
            continue
        }
        
        # Process files in the current directory
        Get-ChildItem -Path $currentDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_
            $relativePath = Get-RelativePath -BasePath $normalizedDestinationPath -FullPath $file.FullName
            
            if ([string]::IsNullOrEmpty($relativePath)) { return }
            
            if (Test-ShouldCount -Path $relativePath -IncludePatterns $IncludePatterns -ExcludePatterns $ExcludePatterns) {
                $srcFilePath = Join-PathSafely -Path $normalizedSourcePath -ChildPath $relativePath
                
                if (-not (Test-Path -Path $srcFilePath -PathType Leaf)) {
                    [void]$extraFiles.Add($relativePath)
                }
            }
        }
        
        # Queue subdirectories for processing
        Get-ChildItem -Path $currentDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $destStack.Push($_.FullName)
        }
    }
    
    # Report results
    if ($missingFiles.Count -gt 0) {
        Write-Log "The following files are missing from destination:" -Level Warning
        foreach ($file in $missingFiles) {
            Write-Log "  $file" -Level Warning
        }
    }
    
    if ($extraFiles.Count -gt 0) {
        Write-Log "The following extra files were found in destination:" -Level Warning
        foreach ($file in $extraFiles) {
            Write-Log "  $file" -Level Warning
        }
    }
    
    if ($missingFiles.Count -eq 0 -and $extraFiles.Count -eq 0) {
        Write-Log "Directory structure verification successful."
    }
    
    # Clean up
    $missingFiles = $null
    $extraFiles = $null
    [System.GC]::Collect()
}

# Optimized version of Start-FileBatchProcessing
#region Main Script Execution

# Set default blacklist if user does not provide one.
# These patterns exclude files that are tied to the old system's configuration.
if (-not $Blacklist) {
    $Blacklist = @(
        "*Config.log*",
        "*GameVersion.txt*",
        "*localthumbcache.package*",
        "*avatarcache.package*",
        "*\ConfigOverride\*",
        "*lastUIstate.txt*",
        "*lastCrash.txt*",
        "*.bad",
        "*.ds_store",
        "*\Cache\*",
        "*\cachedata\*"
    )
}

# Normalize paths
$normalizedSourcePath = Convert-PathFormat -Path $SourcePath
$normalizedDestinationPath = Convert-PathFormat -Path $DestinationPath

# Stats tracking variables
$script:filesProcessed = 0
$script:filesSkipped = 0
$script:filesCopied = 0
$script:filesWithErrors = 0
$script:totalFiles = 0

# Begin Script Execution
Write-Log "Starting Sims 4 data transfer with memory-optimized processing..."
Write-Log "Source: $normalizedSourcePath"
Write-Log "Destination: $normalizedDestinationPath"

# Ensure Sims 4 is not running.
Test-SimsRunning

# Verify that the source path exists.
if (-not (Test-PathAndLog -Path $normalizedSourcePath -Description "Source path" -Critical)) {
    exit 1
}

# Verify or create the destination path.
if (-not (Test-Path -Path $normalizedDestinationPath)) {
    Write-Log "Destination path '$normalizedDestinationPath' does not exist. Creating directory..."
    try {
        if (-not $WhatIf) {
            New-DirectorySafely -Path $normalizedDestinationPath -IsWhatIf $false | Out-Null
        } else {
            Write-Log "Would create destination directory: $normalizedDestinationPath (WhatIf mode)"
        }
    }
    catch {
        Write-Log "Failed to create destination directory. $_" -Level Critical
        exit 1
    }
} elseif ($Backup) {
    # Create backup if requested and destination exists
    $backupLocation = Backup-DestinationFolder -Path $normalizedDestinationPath
    if ($null -ne $backupLocation) {
        Write-Log "Backup location: $backupLocation"
    }
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
Write-Log "Counting files to process (this may take a moment for large directories)..."
$script:totalFiles = Get-TotalFileCount -Path $normalizedSourcePath -BlacklistPatterns $Blacklist
Write-Log "Estimated total files to process: $script:totalFiles"

# If we have a large number of files, adjust the batch size to conserve memory
if ($script:totalFiles -gt 5000) {
    $originalBatchSize = $BatchSize
    $BatchSize = [Math]::Min($BatchSize, 20)
    Write-Log "Large file set detected ($script:totalFiles files). Reducing batch size from $originalBatchSize to $BatchSize to conserve memory."
}

# Create an array to track all active jobs
$activeJobs = @()
$activeJobsRef = [ref]$activeJobs

# Process the Options.ini file separately if required
if ($TransferOptions) {
    $optionsFile = Join-PathSafely -Path $normalizedSourcePath -ChildPath "Options.ini"
    if (Test-Path $optionsFile) {
        Write-Log "Processing Options.ini file"
        $optionsFileInfo = Get-Item $optionsFile
        $optionsBatch = @($optionsFileInfo)
        $optionsJobs = Start-FileBatchProcessing -FileBatch $optionsBatch -SourceRoot $normalizedSourcePath -DestinationRoot $normalizedDestinationPath -BlacklistPatterns $Blacklist -IsWhatIf $WhatIf -UseForce $Force
        $activeJobs += $optionsJobs
    }
    else {
        Write-Log "Options.ini file not found at: $optionsFile" -Level Warning
    }
}

# Define directories to process based on selected options
$directories = @()
if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots) {
    if ($TransferSaves) { 
        $savesDir = Join-PathSafely -Path $normalizedSourcePath -ChildPath "Saves"
        if (Test-Path -Path $savesDir) { 
            $directories += $savesDir 
        }
        else {
            Write-Log "Saves directory not found at: $savesDir" -Level Warning
        }
    }
    if ($TransferMods) { 
        $modsDir = Join-PathSafely -Path $normalizedSourcePath -ChildPath "Mods"
        if (Test-Path -Path $modsDir) { 
            $directories += $modsDir 
        }
        else {
            Write-Log "Mods directory not found at: $modsDir" -Level Warning
        }
    }
    if ($TransferTray) { 
        $trayDir = Join-PathSafely -Path $normalizedSourcePath -ChildPath "Tray"
        if (Test-Path -Path $trayDir) { 
            $directories += $trayDir 
        }
        else {
            Write-Log "Tray directory not found at: $trayDir" -Level Warning
        }
    }
    if ($TransferScreenshots) { 
        $screenshotsDir = Join-PathSafely -Path $normalizedSourcePath -ChildPath "Screenshots"
        if (Test-Path -Path $screenshotsDir) { 
            $directories += $screenshotsDir 
        }
        else {
            Write-Log "Screenshots directory not found at: $screenshotsDir" -Level Warning
        }
    }
} else {
    # If no specific options selected, process the whole directory
    $directories += $normalizedSourcePath
}

# Process each main directory using improved directory processing
Write-Log "Starting file transfer..."
foreach ($directory in $directories) {
    Start-DirectoryProcessing -Directory $directory -SourceRoot $normalizedSourcePath -DestinationRoot $normalizedDestinationPath -BlacklistPatterns $Blacklist -IsWhatIf $WhatIf -UseForce $Force -BatchSize $BatchSize -ActiveJobsRef $activeJobsRef -MaxParallelJobs $MaxParallelJobs
    
    # Force garbage collection between directories
    [System.GC]::Collect()
}

# Wait for all remaining jobs to complete
Write-Log "Waiting for remaining file copy operations to complete..."
$activeJobs = Wait-ForCompletedJobs -Jobs $activeJobs -WaitForAll $true

# Ensure progress bar is completed
Write-Progress -Activity "Transferring Sims 4 Files" -Status "Complete" -PercentComplete 100 -Completed

# Build include patterns based on selective transfer options
$includePatterns = @()
if ($TransferSaves -or $TransferMods -or $TransferTray -or $TransferScreenshots -or $TransferOptions) {
    if ($TransferSaves) { $includePatterns += "*\Saves\*" }
    if ($TransferMods) { $includePatterns += "*\Mods\*" }
    if ($TransferTray) { $includePatterns += "*\Tray\*" }
    if ($TransferScreenshots) { $includePatterns += "*\Screenshots\*" }
    if ($TransferOptions) { $includePatterns += "*Options.ini*" }
}

# Verify overall directory structure if requested
if ($VerifyStructure) {
    Write-Log "Verifying overall directory structure and file locations..."
    Compare-DirectoryStructures -SourcePath $normalizedSourcePath -DestinationPath $normalizedDestinationPath -IncludePatterns $includePatterns -ExcludePatterns $Blacklist -IsWhatIf $WhatIf
}

# Display summary
Write-Log "Transfer Summary:"
Write-Log "----------------"
Write-Log "Files processed: $script:filesProcessed"
Write-Log "Files copied: $script:filesCopied"
Write-Log "Files skipped: $script:filesSkipped"
if ($script:filesWithErrors -gt 0) {
    Write-Log "Files with errors: $script:filesWithErrors" -Level Warning
}
Write-Log "----------------"
Write-Log "Sims 4 data transfer completed."

# Final cleanup
[System.GC]::Collect()

#endregion Main Script Execution

# Function: Wait-ForCompletedJobs
# Waits for jobs to complete and processes their results
function Wait-ForCompletedJobs {
    param (
        [array]$Jobs,
        [bool]$WaitForAll = $false
    )
    
    $remainingJobs = @()
    $jobsToReceive = @()
    
    # First identify which jobs are completed or need to be waited on
    foreach ($job in $Jobs) {
        if ($null -eq $job) {
            continue
        }
        
        if ($job.State -ne "Running" -or $WaitForAll) {
            if ($WaitForAll -and $job.State -eq "Running") {
                $job | Wait-Job | Out-Null
            }
            
            $jobsToReceive += $job
        }
        else {
            $remainingJobs += $job
        }
    }
    
    # Process all completed jobs in one batch
    if ($jobsToReceive.Count -gt 0) {
        try {
            foreach ($job in $jobsToReceive) {
                $result = Receive-Job -Job $job -ErrorAction Stop
                
                # The jobs now return an array of results, handle each one
                if ($result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
                    foreach ($item in $result) {
                        if ($null -eq $item) { continue }
                        
                        if ($item.Success) {
                            Write-Log "Copied file: $($item.RelativePath)"
                            $script:filesCopied++
                        }
                        else {
                            Write-Log "Error copying file '$($item.RelativePath)': $($item.Error)" -Level Error
                            $script:filesWithErrors++
                        }
                    }
                }
                elseif ($null -ne $result) {
                    if ($result.Success) {
                        Write-Log "Copied file: $($result.RelativePath)"
                        $script:filesCopied++
                    }
                    else {
                        Write-Log "Error copying file '$($result.RelativePath)': $($result.Error)" -Level Error
                        $script:filesWithErrors++
                    }
                }
                
                # Remove the job immediately after processing
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Log "Error processing jobs: $_" -Level Error
            
            # Clean up the jobs even if there was an error
            foreach ($job in $jobsToReceive) {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
        
        # Force garbage collection after processing a batch of jobs
        [System.GC]::Collect()
    }
    
    return $remainingJobs
}

# New function to handle job batching
function Start-BatchedJobs {
    param (
        [System.Management.Automation.Job[]]$Jobs,
        [ref]$ActiveJobsRef,
        [int]$MaxJobs
    )
    
    # Add new jobs to active jobs
    $ActiveJobsRef.Value += $Jobs
    
    # Process completed jobs when we reach the maximum
    if ($ActiveJobsRef.Value.Count -ge $MaxJobs) {
        # Wait for at least some jobs to complete
        Start-Sleep -Milliseconds 500
        $ActiveJobsRef.Value = Wait-ForCompletedJobs -Jobs $ActiveJobsRef.Value
        
        # Force garbage collection
        [System.GC]::Collect()
    }
}

# Optimized version of Start-FileBatchProcessing
function Start-FileBatchProcessing {
    param (
        [System.IO.FileInfo[]]$FileBatch,
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$BlacklistPatterns,
        [bool]$IsWhatIf,
        [bool]$UseForce
    )
    
    $batchJobs = New-Object System.Collections.ArrayList
    
    foreach ($file in $FileBatch) {
        if ($null -eq $file) {
            Write-Log "Null file encountered in batch processing. Skipping." -Level Warning
            continue
        }
        
        if ([string]::IsNullOrWhiteSpace($file.FullName)) {
            Write-Log "File with empty path encountered. Skipping." -Level Warning
            continue
        }
        
        if (-not (Test-Path -Path $file.FullName -PathType Leaf)) {
            Write-Log "File no longer exists: $($file.FullName). Skipping." -Level Warning
            continue
        }
        
        # Compute the file's relative path with improved error handling
        $relativePath = Get-RelativePath -BasePath $SourceRoot -FullPath $file.FullName
        
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            Write-Log "Could not determine relative path for '$($file.FullName)'. Skipping file." -Level Error
            $script:filesSkipped++
            continue
        }
        
        # Skip this file if it matches any blacklist pattern
        if (Test-Blacklisted -RelativePath $relativePath -BlacklistPatterns $BlacklistPatterns) {
            Write-Log "Skipping blacklisted file: $relativePath" -Level Info
            $script:filesSkipped++
            continue
        }
        
        # Skip this file if it doesn't match inclusion criteria
        if (-not (Test-ShouldInclude -RelativePath $relativePath)) {
            $script:filesSkipped++
            continue
        }
        
        # Only increment processed files counter AFTER all filtering is complete
        $script:filesProcessed++
        
        # Build the full destination file path using the safe join function
        $destFile = Join-PathSafely -Path $DestinationRoot -ChildPath $relativePath
        
        if ([string]::IsNullOrWhiteSpace($destFile)) {
            Write-Log "Could not construct destination path for '$relativePath'. Skipping file." -Level Error
            $script:filesSkipped++
            continue
        }
        
        # Ensure the destination directory exists
        $destDir = Split-Path -Path $destFile -Parent
        if ([string]::IsNullOrWhiteSpace($destDir)) {
            Write-Log "Could not determine parent directory for '$destFile'. Skipping file." -Level Error
            $script:filesSkipped++
            continue
        }
        
        $dirCreated = New-DirectorySafely -Path $destDir -IsWhatIf $IsWhatIf
        if (-not $dirCreated -and -not $IsWhatIf) {
            Write-Log "Failed to create directory '$destDir'. Skipping file '$relativePath'." -Level Error
            $script:filesWithErrors++
            continue
        }
        
        # Decide if the file should be copied
        $copyFile = $true
        
        # If the file exists in the destination, compare metadata and file hash
        if (Test-Path -Path $destFile) {
            try {
                $destInfo = Get-Item -Path $destFile
                # First, compare file size and last write time - this is more memory efficient than computing hashes
                if (($file.Length -eq $destInfo.Length) -and ($file.LastWriteTime -eq $destInfo.LastWriteTime)) {
                    # Only compute hashes if metadata matches - reduces unnecessary hash calculations
                    $srcHash = (Get-FileHash -Path $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                    $destHash = (Get-FileHash -Path $destFile -Algorithm SHA256 -ErrorAction Stop).Hash
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
                    # File metadata differs - will copy the file
                    Write-Log "File $relativePath differs (metadata mismatch). Will copy file."
                }
            }
            catch {
                Write-Log "Error comparing files for '$relativePath': $_. Will copy file." -Level Warning
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
                    param($src, $dest, $force, $relativePath)
                    try {
                        # Ensure destination directory exists (for safety)
                        $destDir = Split-Path -Path $dest -Parent
                        if (-not (Test-Path -Path $destDir)) {
                            New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                        }
                        
                        if ($force) {
                            Copy-Item -Path $src -Destination $dest -Force
                        } else {
                            Copy-Item -Path $src -Destination $dest
                        }
                        
                        return @{Success = $true; Path = $dest; RelativePath = $relativePath}
                    } catch {
                        return @{Success = $false; Path = $dest; RelativePath = $relativePath; Error = $_.Exception.Message}
                    }
                } -ArgumentList $file.FullName, $destFile, $UseForce, $relativePath
                
                [void]$batchJobs.Add($job)
            }
        }
        
        # Clear variables to help with garbage collection
        $destInfo = $null
        $srcHash = $null
        $destHash = $null
    }
    
    return $batchJobs
}