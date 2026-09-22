<#
.SYNOPSIS
    Minifies C# and Java source files (strips comments, blank lines, and
    redundant whitespace) to cut token usage when pasting/uploading code
    to an AI assistant.

.DESCRIPTION
    Recursively scans -Path for files matching -Extensions, strips:
      - // line comments and /* */ block comments
      - leading indentation and repeated inline whitespace
      - blank lines
    while staying aware of string/char literals (including @"..." verbatim
    strings and """...""" triple-quoted blocks) so it won't touch text that
    looks like a comment but is actually inside a string.

    By default all minified files are concatenated into one combined
    output file (with a header before each file) so you can upload a
    single file instead of many. Pass -OutDir to also/instead write out
    individually minified files mirroring the source folder structure.

.PARAMETER Path
    Root folder to scan. Defaults to the current directory.

.PARAMETER OutFile
    Path to the combined output file. Defaults to ./minified.txt.
    Pass -OutFile '' (empty string) to skip writing the combined file.

.PARAMETER OutDir
    Optional folder to write individually minified files into, mirroring
    the relative path of each source file.

.PARAMETER Extensions
    File extensions to include (without dot). Defaults to cs, java.

.PARAMETER ExcludeDirs
    Directory names to skip anywhere in the tree. Defaults to common
    build/vcs/package folders.

.EXAMPLE
    ./Minify-Code.ps1 -Path ./MyProject -OutFile ./upload.txt

.EXAMPLE
    ./Minify-Code.ps1 -Path ./MyProject -OutDir ./MyProject-min -OutFile ''
#>

[CmdletBinding()]
param(
    [string]$Path = '.',
    [string]$OutFile = './minified.txt',
    [string]$OutDir = '',
    [string[]]$Extensions = @('cs', 'java'),
    [string[]]$ExcludeDirs = @('bin', 'obj', '.git', '.vs', '.idea', 'node_modules', 'target', 'build', 'packages', 'out')
)

function Convert-MinifiedContent {
    param([Parameter(Mandatory)][string]$Content)

    $chars = $Content.ToCharArray()
    $len = $chars.Length
    $sb = [System.Text.StringBuilder]::new($len)

    # States
    $Normal = 0
    $LineComment = 1
    $BlockComment = 2
    $InString = 3
    $InChar = 4
    $InTripleString = 5

    $state = $Normal
    $verbatim = $false
    $atLineStart = $true
    $i = 0

    while ($i -lt $len) {
        $c = $chars[$i]
        $n = if ($i + 1 -lt $len) { $chars[$i + 1] } else { [char]0 }
        $n2 = if ($i + 2 -lt $len) { $chars[$i + 2] } else { [char]0 }

        switch ($state) {
            $Normal {
                if ($c -eq "`n") {
                    [void]$sb.Append($c)
                    $atLineStart = $true
                    $i++
                    continue
                }

                if ($atLineStart -and ($c -eq ' ' -or $c -eq "`t")) {
                    # swallow leading indentation
                    $i++
                    continue
                }
                $atLineStart = $false

                if ($c -eq '/' -and $n -eq '/') {
                    $state = $LineComment
                    $i += 2
                    continue
                }
                if ($c -eq '/' -and $n -eq '*') {
                    $state = $BlockComment
                    $i += 2
                    continue
                }
                if ($c -eq '"' -and $n -eq '"' -and $n2 -eq '"') {
                    [void]$sb.Append('"""')
                    $state = $InTripleString
                    $i += 3
                    continue
                }
                if ($c -eq '"') {
                    $verbatim = ($i -gt 0 -and $chars[$i - 1] -eq '@')
                    [void]$sb.Append($c)
                    $state = $InString
                    $i++
                    continue
                }
                if ($c -eq "'") {
                    [void]$sb.Append($c)
                    $state = $InChar
                    $i++
                    continue
                }
                if ($c -eq ' ' -or $c -eq "`t") {
                    # collapse a run of inline whitespace into a single space
                    [void]$sb.Append(' ')
                    while ($i -lt $len -and ($chars[$i] -eq ' ' -or $chars[$i] -eq "`t")) { $i++ }
                    continue
                }

                [void]$sb.Append($c)
                $i++
                continue
            }

            $LineComment {
                if ($c -eq "`n") {
                    $state = $Normal
                    [void]$sb.Append($c)
                    $atLineStart = $true
                }
                $i++
                continue
            }

            $BlockComment {
                if ($c -eq '*' -and $n -eq '/') {
                    $state = $Normal
                    $i += 2
                } else {
                    $i++
                }
                continue
            }

            $InString {
                [void]$sb.Append($c)
                if ($verbatim) {
                    if ($c -eq '"') {
                        if ($n -eq '"') {
                            [void]$sb.Append($n)
                            $i += 2
                        } else {
                            $state = $Normal
                            $i++
                        }
                    } else {
                        $i++
                    }
                } else {
                    if ($c -eq '\' -and $i + 1 -lt $len) {
                        [void]$sb.Append($n)
                        $i += 2
                    } elseif ($c -eq '"') {
                        $state = $Normal
                        $i++
                    } else {
                        $i++
                    }
                }
                continue
            }

            $InChar {
                [void]$sb.Append($c)
                if ($c -eq '\' -and $i + 1 -lt $len) {
                    [void]$sb.Append($n)
                    $i += 2
                } elseif ($c -eq "'") {
                    $state = $Normal
                    $i++
                } else {
                    $i++
                }
                continue
            }

            $InTripleString {
                if ($c -eq '"' -and $n -eq '"' -and $n2 -eq '"') {
                    [void]$sb.Append('"""')
                    $state = $Normal
                    $i += 3
                } else {
                    [void]$sb.Append($c)
                    $i++
                }
                continue
            }
        }
    }

    $text = $sb.ToString()
    # collapse runs of blank lines left behind by removed comments
    $text = [regex]::Replace($text, '(\r?\n)[ \t]*(\r?\n[ \t]*)+', '$1')
    # trim trailing whitespace on each line and leading/trailing blank lines
    $text = [regex]::Replace($text, '[ \t]+\r?\n', "`n")
    return $text.Trim()
}

$root = (Resolve-Path -LiteralPath $Path).Path
$extsWanted = $Extensions | ForEach-Object { $_.TrimStart('.').ToLowerInvariant() }

$files = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object {
        $extsWanted -contains $_.Extension.TrimStart('.').ToLowerInvariant()
    } |
    Where-Object {
        $relDir = $_.DirectoryName.Substring($root.Length).TrimStart('\', '/')
        $segments = $relDir -split '[\\/]'
        -not ($segments | Where-Object { $ExcludeDirs -contains $_ })
    }

if (-not $files) {
    Write-Warning "No files matching [$($Extensions -join ', ')] found under '$root'."
    return
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$combinedSb = if ($OutFile) { [System.Text.StringBuilder]::new() } else { $null }

$totalOriginalChars = 0
$totalMinifiedChars = 0
$results = @()

foreach ($file in $files) {
    $original = [System.IO.File]::ReadAllText($file.FullName)
    $minified = Convert-MinifiedContent -Content $original

    $relPath = $file.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'

    $totalOriginalChars += $original.Length
    $totalMinifiedChars += $minified.Length
    $results += [pscustomobject]@{
        Path            = $relPath
        OriginalChars   = $original.Length
        MinifiedChars   = $minified.Length
    }

    if ($OutDir) {
        $destPath = Join-Path $OutDir $relPath
        $destDir = Split-Path $destPath -Parent
        if ($destDir -and -not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($destPath, $minified, $utf8NoBom)
    }

    if ($combinedSb) {
        [void]$combinedSb.AppendLine("// ===== $relPath =====")
        [void]$combinedSb.AppendLine($minified)
        [void]$combinedSb.AppendLine()
    }
}

if ($OutFile) {
    $outFileFull = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).Path $OutFile }
    $outFileDir = Split-Path $outFileFull -Parent
    if ($outFileDir -and -not (Test-Path $outFileDir)) {
        New-Item -ItemType Directory -Path $outFileDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($outFileFull, $combinedSb.ToString().TrimEnd() + "`n", $utf8NoBom)
    Write-Host "Combined output written to: $outFileFull"
}

if ($OutDir) {
    Write-Host "Individual minified files written under: $OutDir"
}

$savedChars = $totalOriginalChars - $totalMinifiedChars
$pct = if ($totalOriginalChars -gt 0) { [math]::Round(($savedChars / $totalOriginalChars) * 100, 1) } else { 0 }
$estOrigTokens = [math]::Round($totalOriginalChars / 4)
$estMinTokens = [math]::Round($totalMinifiedChars / 4)

Write-Host ""
Write-Host "Files processed : $($results.Count)"
Write-Host "Original size   : $totalOriginalChars chars (~$estOrigTokens tokens)"
Write-Host "Minified size   : $totalMinifiedChars chars (~$estMinTokens tokens)"
Write-Host "Reduction       : $savedChars chars ($pct%)"
