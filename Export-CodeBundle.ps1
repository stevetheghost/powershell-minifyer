<#
.SYNOPSIS
    Bundles every file in a directory into one text file for uploading to an
    AI, minifying code files along the way to cut token usage.

.DESCRIPTION
    Walks -Path and writes each included file into a single output file, with
    a "==> relative/path <==" header before each one.

    Skipped:
      - VCS and package/dependency folders (.git, node_modules, .gradle, ...)
      - lock files and package-manager config (package-lock.json, *.lock, ...)
      - anything matched by .gitignore (via `git ls-files` when git is
        available, otherwise by parsing the .gitignore files directly)
      - binary files (by extension, or a NUL byte in the first 8 KB)

    Code files are minified in pure PowerShell (regex tokenizer, string-aware):
      - comments removed
      - blank lines, trailing whitespace and leading indentation removed
      - runs of inline whitespace collapsed to one space
      - Python keeps its indentation, reduced to 1 space per level
      - JSON has all whitespace outside strings removed
    Line breaks are kept, so code stays readable and newline-sensitive
    languages (JS ASI, preprocessor directives, shell) keep working.

    With -Aggressive, line breaks and spaces are squeezed out as well:
      - Java, C#, C/C++, Rust, CSS/SCSS: each file goes on one line (C/C#
        preprocessor directives keep their own lines), and spaces next to
        { } ( ) [ ] ; , = are dropped
      - JS/TS, Kotlin, Scala, Swift, Go, Groovy/Gradle, Dart, PHP: a line break
        can end a statement in these, so only breaks that can't are removed
        (after { ( [ , ; = and before } ) ] or a .method() chain)
      - XML: one line, no whitespace between tags or around attribute '=',
        <?xml ...?> declaration dropped
      - HTML/Vue/Svelte: whitespace between tags removed
    JSON is already whitespace-free in the default mode.

    Other text files (markdown, yaml, txt, ...) are included as-is, apart from
    trimming trailing whitespace and collapsing repeated blank lines.

.PARAMETER Path
    Directory to bundle.

.PARAMETER OutFile
    Output file. Defaults to ./<folder-name>-bundle.txt in the current
    directory.

.PARAMETER ExcludeDirs
    Directory names to skip anywhere in the tree.

.PARAMETER ExcludeFiles
    File name wildcards to skip anywhere in the tree.

.PARAMETER NoGitignore
    Don't apply .gitignore rules.

.PARAMETER Aggressive
    Also remove line breaks and spaces around punctuation where the language
    allows it. Fewer tokens, less readable.

.EXAMPLE
    ./Export-CodeBundle.ps1 -Path ./MyProject

.EXAMPLE
    ./Export-CodeBundle.ps1 -Path ./MyProject -Aggressive

.EXAMPLE
    ./Export-CodeBundle.ps1 -Path ./MyProject -OutFile ./upload.txt -ExcludeDirs @('docs') -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$OutFile = '',
    [string[]]$ExcludeDirs = @(
        # version control
        '.git', '.svn', '.hg',
        # package managers / dependency caches
        'node_modules', 'bower_components', 'jspm_packages', '.yarn', '.pnpm-store', '.npm',
        '.gradle', '.nuget', 'vendor', 'Pods', 'Carthage', '.dart_tool', '.pub-cache', 'elm-stuff',
        '__pycache__', '.venv', 'venv', '.tox', '.mypy_cache', '.pytest_cache', 'site-packages',
        # build output / IDE
        'bin', 'obj', 'build', 'dist', 'target', 'out', '.next', '.nuxt', 'coverage', '.idea', '.vs'
    ),
    [string[]]$ExcludeFiles = @(
        # lock files
        'package-lock.json', 'npm-shrinkwrap.json', 'pnpm-lock.yaml', 'bun.lockb', '*.lock', 'go.sum', 'packages.lock.json',
        # package manager / wrapper files
        '.npmrc', '.yarnrc', '.yarnrc.yml', 'gradlew', 'gradlew.bat', 'gradle-wrapper.jar', 'gradle-wrapper.properties',
        # git files
        '.gitignore', '.gitattributes', '.gitmodules', '.gitkeep',
        # secrets
        '.env', '.env.*',
        # generated / low value for an AI
        '*.min.js', '*.min.css', '*.map', '*.svg', '.DS_Store'
    ),
    [switch]$NoGitignore,
    [switch]$Aggressive
)

$BinaryExtensions = @(
    'png', 'jpg', 'jpeg', 'gif', 'bmp', 'ico', 'webp', 'tif', 'tiff', 'psd', 'heic',
    'mp3', 'mp4', 'wav', 'ogg', 'flac', 'mov', 'avi', 'mkv', 'webm',
    'zip', 'gz', 'tgz', 'tar', '7z', 'rar', 'bz2', 'xz',
    'jar', 'war', 'ear', 'aar', 'class', 'dll', 'exe', 'so', 'dylib', 'a', 'lib', 'o', 'obj', 'pdb', 'wasm', 'pyc',
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
    'woff', 'woff2', 'ttf', 'otf', 'eot',
    'db', 'sqlite', 'sqlite3', 'bin', 'dat', 'keystore', 'jks', 'p12', 'pfx'
)

#region Language specs

# Regex building blocks. Each language gets one combined regex whose (?<s>...)
# group matches string literals (kept verbatim) and (?<c>...) group matches
# comments (removed). Everything between matches is code.
$q = "'"
$P = @{
    Dq        = '"(?:\\.|[^"\\\n])*"'
    Sq        = $q + '(?:\\.|[^' + $q + '\\\n])*' + $q
    # char literal like 'a' or '\n'; a lone ' (e.g. a Rust lifetime) is left as code
    Char      = $q + '(?:\\.[^' + $q + '\n]{0,9}|[^' + $q + '\\\n])' + $q
    TripleDq  = '"""(?:\\.|[^\\])*?"""'
    TripleSq  = "$q$q$q" + '(?:\\.|[^\\])*?' + "$q$q$q"
    Template  = '`(?:\\.|[^`\\])*`'
    GoRaw     = '`[^`]*`'
    CsVerb    = '(?:\$@|@\$?)"(?:""|[^"])*"'
    RustRaw   = 'r(?<rh>#+)".*?"\k<rh>'
    # JS regex literal: a / that follows an operator, bracket or keyword
    RegexLit  = '(?<=(?:^|[(,=:\[!&|?{};+\-*%~^]|\b(?:return|typeof|case|do|else|in|of|void|yield|await|delete|throw|new))\s*)/(?![/*])(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\n\[])+/[a-z]*'
    ShSq      = $q + '[^' + $q + ']*' + $q
    DoubledSq = $q + '(?:' + $q + $q + '|[^' + $q + '])*' + $q
    PlainDq   = '"[^"]*"'
    PsDq      = '"(?:`.|""|[^"`])*"'
    PsHereDq  = '@"\n.*?\n"@'
    PsHereSq  = '@' + $q + '\n.*?\n' + $q + '@'
    CssUrl    = 'url\([^)"' + $q + ']*\)'
    LuaLong   = '\[(?<ls>=*)\[.*?\]\k<ls>\]'

    LineC     = '//[^\n]*'
    BlockC    = '/\*.*?\*/'
    Hash      = '#[^\n]*'
    ShHash    = '(?<![^\s;])#[^\n]*'
    PsHash    = '(?<![^\s;{}()|])#[^\n]*'
    PhpHash   = '#(?!\[)[^\n]*'
    PsBlock   = '<#.*?#>'
    HtmlC     = '<!--.*?-->'
    DashC     = '--[^\n]*'
    LuaBlockC = '--\[(?<lc>=*)\[.*?\]\k<lc>\]'
    RubyBlock = '(?<![^\n])=begin\b.*?\n=end[^\n]*'
}

function New-LangSpec {
    param([string[]]$Strings, [string[]]$Comments, [string]$Mode, [hashtable]$Aggr)
    $parts = @()
    if ($Strings) { $parts += '(?<s>' + ($Strings -join '|') + ')' }
    if ($Comments) { $parts += '(?<c>' + ($Comments -join '|') + ')' }
    [pscustomobject]@{
        Regex = [regex]::new(($parts -join '|'), 'Singleline')
        Mode  = $Mode   # strip | indent | json
        Aggr  = $Aggr   # -Aggressive rules, see Convert-AggressiveContent
    }
}

# Matches spaces that can be dropped next to the given punctuation. With
# -Equals, spaces around '=' go too, except right after another operator
# character, so `x! = y` (TypeScript) never turns into `x!=y`.
function Get-SpacingPattern {
    param([string]$Chars, [switch]$Equals)
    $p = "(?<=[$Chars])[ \t]+|[ \t]+(?=[$Chars])"
    if ($Equals) { $p += '|(?<==)[ \t]+|(?<![!<>=+\-*/%&|^~?:.])[ \t]+(?==)' }
    return $p
}

$SpaceBrace = Get-SpacingPattern '{}()\[\];,' -Equals
$AggrJoin   = @{ Style = 'join'; Spacing = $SpaceBrace }
$AggrJoinPP = @{ Style = 'join'; Spacing = $SpaceBrace; Directives = $true }
$AggrLines  = @{ Style = 'lines'; JoinAfter = '{(\[,;='; Spacing = $SpaceBrace }
# Swift errors on lopsided spacing around operators (`a !=b`), so it only
# gets the safe line joins, and never after '='.
$AggrSwift  = @{ Style = 'lines'; JoinAfter = '{(\[,;' }
# CSS: spaces matter around ( ) (`and (max-width...)`), so only { } ; , and after ':'
$AggrCss    = @{ Style = 'join'; Spacing = '(?<=[{};,:])[ \t]+|[ \t]+(?=[{};,])' }

$Specs = @{
    c      = New-LangSpec @($P.Dq, $P.Char) @($P.LineC, $P.BlockC) 'strip' $AggrJoinPP
    cs     = New-LangSpec @($P.TripleDq, $P.CsVerb, $P.Dq, $P.Char) @($P.LineC, $P.BlockC) 'strip' $AggrJoinPP
    java   = New-LangSpec @($P.TripleDq, $P.Dq, $P.Char) @($P.LineC, $P.BlockC) 'strip' $AggrJoin
    jvm    = New-LangSpec @($P.TripleDq, $P.Dq, $P.Char) @($P.LineC, $P.BlockC) 'strip' $AggrLines
    swift  = New-LangSpec @($P.TripleDq, $P.Dq) @($P.LineC, $P.BlockC) 'strip' $AggrSwift
    groovy = New-LangSpec @($P.TripleDq, $P.TripleSq, $P.Dq, $P.Sq) @($P.LineC, $P.BlockC) 'strip' $AggrLines
    js     = New-LangSpec @($P.RegexLit, $P.Template, $P.Dq, $P.Sq) @($P.LineC, $P.BlockC) 'strip' $AggrLines
    go     = New-LangSpec @($P.GoRaw, $P.Dq, $P.Char) @($P.LineC, $P.BlockC) 'strip' $AggrLines
    rust   = New-LangSpec @($P.RustRaw, $P.Dq, $P.Char) @($P.LineC, $P.BlockC) 'strip' $AggrJoin
    php    = New-LangSpec @($P.Dq, $P.Sq) @($P.LineC, $P.BlockC, $P.PhpHash) 'strip' $AggrLines
    css    = New-LangSpec @($P.CssUrl, $P.Dq, $P.Sq) @($P.BlockC) 'strip' $AggrCss
    scss   = New-LangSpec @($P.CssUrl, $P.Dq, $P.Sq) @($P.LineC, $P.BlockC) 'strip' $AggrCss
    sql    = New-LangSpec @($P.DoubledSq, $P.PlainDq) @($P.DashC, $P.BlockC) 'strip'
    python = New-LangSpec @($P.TripleDq, $P.TripleSq, $P.Dq, $P.Sq) @($P.Hash) 'indent'
    ruby   = New-LangSpec @($P.Dq, $P.Sq) @($P.RubyBlock, $P.Hash) 'strip'
    shell  = New-LangSpec @($P.ShSq, $P.Dq) @($P.ShHash) 'strip'
    ps     = New-LangSpec @($P.PsHereDq, $P.PsHereSq, $P.PsDq, $P.DoubledSq) @($P.PsBlock, $P.PsHash) 'strip'
    lua    = New-LangSpec @($P.LuaLong, $P.Dq, $P.Sq) @($P.LuaBlockC, $P.DashC) 'strip'
    r      = New-LangSpec @($P.Dq, $P.Sq) @($P.Hash) 'strip'
    json   = New-LangSpec @($P.Dq) @($P.LineC, $P.BlockC) 'json'
    xml    = New-LangSpec @() @($P.HtmlC) 'strip' @{ Style = 'xml' }
    html   = New-LangSpec @() @($P.HtmlC) 'strip' @{ Style = 'html' }
}

$ExtensionMap = @{}
$langExts = @{
    c      = 'c h cpp cc cxx hpp hh hxx m mm ino'
    cs     = 'cs'
    java   = 'java'
    jvm    = 'kt kts scala sc'
    swift  = 'swift'
    groovy = 'groovy gradle dart'
    js     = 'js jsx mjs cjs ts tsx mts cts'
    go     = 'go'
    rust   = 'rs'
    php    = 'php'
    css    = 'css'
    scss   = 'scss less'
    sql    = 'sql'
    python = 'py pyw pyi'
    ruby   = 'rb rake'
    shell  = 'sh bash zsh ksh'
    ps     = 'ps1 psm1 psd1'
    lua    = 'lua'
    r      = 'r'
    json   = 'json jsonc ipynb'
    xml    = 'xml xaml xsd csproj vbproj fsproj props targets config resx plist'
    html   = 'html htm xhtml vue svelte cshtml razor'
}
foreach ($lang in $langExts.Keys) {
    foreach ($ext in $langExts[$lang] -split ' ') { $ExtensionMap[$ext] = $Specs[$lang] }
}
$FileNameMap = @{ 'jenkinsfile' = $Specs.groovy }

function Get-LangSpec {
    param([string]$FileName)
    $lower = $FileName.ToLowerInvariant()
    if ($FileNameMap.ContainsKey($lower)) { return $FileNameMap[$lower] }
    $ext = [System.IO.Path]::GetExtension($lower).TrimStart('.')
    if ($ext -and $ExtensionMap.ContainsKey($ext)) { return $ExtensionMap[$ext] }
    return $null
}

#endregion

#region Minification

# Runs after the normal minification, on text where string literals have been
# replaced by placeholders, so none of these rules can touch string contents.
function Convert-AggressiveContent {
    param([string]$Text, [hashtable]$Aggr)

    switch ($Aggr.Style) {
        'join' {
            # Line breaks are plain whitespace in these languages, so put
            # everything on one line. Preprocessor directives (and their \
            # continuations) must keep their own lines.
            $out = [System.Collections.Generic.List[string]]::new()
            $chunk = [System.Collections.Generic.List[string]]::new()
            $flush = {
                if ($chunk.Count) {
                    $one = [regex]::Replace(($chunk -join ' '), '[ \t]{2,}', ' ')
                    $out.Add([regex]::Replace($one, $Aggr.Spacing, ''))
                    $chunk.Clear()
                }
            }
            $inDirective = $false
            foreach ($line in $Text -split "`n") {
                if ($Aggr.Directives -and ($inDirective -or $line.StartsWith('#'))) {
                    . $flush
                    $out.Add($line)
                    $inDirective = $line.EndsWith('\')
                } else {
                    $chunk.Add($line)
                }
            }
            . $flush
            return $out -join "`n"
        }
        'lines' {
            # A line break can end a statement here (JS ASI, optional semicolons),
            # so only drop the ones that can't: after an opening bracket, comma,
            # semicolon or '=', and before a closing bracket or a .method() chain.
            # Lines starting with '#' (Swift #if, JS #private) are left alone.
            $Text = [regex]::Replace($Text, "(?<=[$($Aggr.JoinAfter)])\n(?!#)|(?<!(?:^|\n)#[^\n]*)\n(?=[})\].])", '')
            if ($Aggr.Spacing) { $Text = [regex]::Replace($Text, $Aggr.Spacing, '') }
            return $Text
        }
        'xml' {
            $Text = [regex]::Replace($Text, '^<\?xml[^>]*\?>', '')
            $Text = [regex]::Replace($Text, '\s+', ' ')
            $Text = $Text.Replace('> <', '><')
            $Text = [regex]::Replace($Text, ' (?=/?>)', '')
            return [regex]::Replace($Text, ' ?= ?(?=["' + $q + '])', '=')
        }
        'html' {
            # only between tags: <script> blocks inside still need their line breaks
            $Text = [regex]::Replace($Text, '>\s+<', '><')
            return [regex]::Replace($Text, '[ \t]+(?=/?>)', '')
        }
    }
    return $Text
}

function Convert-MinifiedContent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content, $Spec, [switch]$Aggressive)

    $text = $Content -replace "\r\n?", "`n"

    if (-not $Spec) {
        # plain text: trim trailing whitespace, collapse repeated blank lines
        $text = [regex]::Replace($text, '[ \t]+(?=\n|$)', '')
        $text = [regex]::Replace($text, '\n{3,}', "`n`n")
        return $text.Trim()
    }

    # Split into alternating [code, string, code, string, ..., code] segments,
    # dropping comments from the code segments as we go.
    $segs = [System.Collections.Generic.List[string]]::new()
    $code = [System.Text.StringBuilder]::new()
    $pos = 0
    foreach ($m in $Spec.Regex.Matches($text)) {
        [void]$code.Append($text, $pos, $m.Index - $pos)
        if ($m.Groups['c'].Success) {
            # keep a line break if the comment spanned lines, otherwise keep tokens apart
            [void]$code.Append($(if ($m.Value.Contains("`n")) { "`n" } else { ' ' }))
        } else {
            $segs.Add($code.ToString())
            [void]$code.Clear()
            $segs.Add($m.Value)
        }
        $pos = $m.Index + $m.Length
    }
    [void]$code.Append($text, $pos, $text.Length - $pos)
    $segs.Add($code.ToString())

    # Code segments sit at even indices; strings are never touched.
    for ($i = 0; $i -lt $segs.Count; $i += 2) {
        $t = $segs[$i]
        switch ($Spec.Mode) {
            'json' {
                $t = [regex]::Replace($t, '\s+', '')
            }
            'strip' {
                # trailing whitespace, blank lines and indentation in one pass
                $t = [regex]::Replace($t, '[ \t]*\n\s*', "`n")
                $t = [regex]::Replace($t, '[ \t]+', ' ')
            }
            'indent' {
                $t = [regex]::Replace($t, '[ \t]+(?=\n)', '')
                $t = [regex]::Replace($t, '\n(?:[ \t]*\n)+', "`n")
                # collapse inline runs, but not indentation (which follows \n)
                $t = [regex]::Replace($t, '(?<!\s)[ \t]{2,}', ' ')
            }
        }
        $segs[$i] = $t
    }

    if ($Spec.Mode -eq 'indent') {
        # Shrink indentation to 1 space per level. Dividing by the smallest
        # indent keeps block levels distinct and consistent.
        $hasTabs = $false
        $unit = [int]::MaxValue
        for ($i = 0; $i -lt $segs.Count; $i += 2) {
            if ($segs[$i] -match '\n *\t') { $hasTabs = $true; break }
            foreach ($m in [regex]::Matches($segs[$i], '\n( +)')) {
                $unit = [math]::Min($unit, $m.Groups[1].Length)
            }
        }
        if (-not $hasTabs -and $unit -gt 1 -and $unit -ne [int]::MaxValue) {
            $evaluator = { param($m) "`n" + (' ' * [math]::Floor($m.Groups[1].Length / $unit)) }.GetNewClosure()
            for ($i = 0; $i -lt $segs.Count; $i += 2) {
                $segs[$i] = [regex]::Replace($segs[$i], '\n( +)', $evaluator)
            }
        }
    }

    if ($Aggressive -and $Spec.Aggr) {
        # Swap each string for a placeholder so the aggressive rules can work
        # across the whole file without seeing string contents.
        $sb = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($i % 2) { [void]$sb.Append([char]0xE000).Append($i).Append([char]0xE001) }
            else { [void]$sb.Append($segs[$i]) }
        }
        $joined = Convert-AggressiveContent -Text $sb.ToString().Trim() -Aggr $Spec.Aggr
        $restore = { param($m) $segs[[int]$m.Groups[1].Value] }.GetNewClosure()
        return [regex]::Replace($joined, '(\d+)', $restore).Trim()
    }

    return ($segs -join '').Trim()
}

#endregion

#region File discovery

function ConvertFrom-GitignoreLine {
    param([string]$Line)

    $l = $Line.TrimEnd()
    if (-not $l -or $l.StartsWith('#')) { return $null }
    $negate = $false
    if ($l.StartsWith('!')) { $negate = $true; $l = $l.Substring(1) }
    elseif ($l.StartsWith('\')) { $l = $l.Substring(1) }
    $dirOnly = $l.EndsWith('/')
    $l = $l.TrimEnd('/')
    $anchored = $l.Contains('/')
    $l = $l.TrimStart('/')
    if (-not $l) { return $null }

    $sb = [System.Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $l.Length) {
        $c = $l[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $l.Length -and $l[$i + 1] -eq '*') {
                $atSegStart = ($i -eq 0 -or $l[$i - 1] -eq '/')
                if ($atSegStart -and $i + 2 -eq $l.Length) {
                    [void]$sb.Append('.*'); $i += 2; continue
                }
                if ($atSegStart -and $i + 2 -lt $l.Length -and $l[$i + 2] -eq '/') {
                    [void]$sb.Append('(?:.*/)?'); $i += 3; continue
                }
                [void]$sb.Append('[^/]*'); $i += 2; continue
            }
            [void]$sb.Append('[^/]*')
        } elseif ($c -eq '?') {
            [void]$sb.Append('[^/]')
        } elseif ($c -eq '[') {
            $close = $l.IndexOf(']', $i + 1)
            if ($close -gt $i + 1) {
                $cls = $l.Substring($i + 1, $close - $i - 1)
                if ($cls.StartsWith('!')) { $cls = '^' + $cls.Substring(1) }
                [void]$sb.Append("[$cls]")
                $i = $close
            } else {
                [void]$sb.Append('\[')
            }
        } elseif ($c -eq '\' -and $i + 1 -lt $l.Length) {
            $i++
            [void]$sb.Append([regex]::Escape([string]$l[$i]))
        } else {
            [void]$sb.Append([regex]::Escape([string]$c))
        }
        $i++
    }

    $pattern = if ($anchored) { '^' + $sb.ToString() + '$' } else { '^(?:.*/)?' + $sb.ToString() + '$' }
    [pscustomobject]@{
        Regex   = [regex]::new($pattern, 'IgnoreCase, CultureInvariant')
        Negate  = $negate
        DirOnly = $dirOnly
    }
}

function Test-GitIgnored {
    param($Rules, [string]$RelPath, [bool]$IsDir)
    $ignored = $false
    foreach ($r in $Rules) {
        if ($r.DirOnly -and -not $IsDir) { continue }
        if ($r.Base) {
            if (-not $RelPath.StartsWith($r.Base + '/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $sub = $RelPath.Substring($r.Base.Length + 1)
        } else {
            $sub = $RelPath
        }
        # last matching rule wins
        if ($r.Rule.Regex.IsMatch($sub)) { $ignored = -not $r.Rule.Negate }
    }
    return $ignored
}

# Uses git itself when possible: it handles every .gitignore rule, nested
# ignores, .git/info/exclude and global excludes exactly as git does.
function Get-GitFileList {
    param([string]$Root)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $inside = & git -C $Root rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') { return $null }

    $prevEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $raw = & git -C $Root ls-files --cached --others --exclude-standard -z 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
    } finally {
        [Console]::OutputEncoding = $prevEncoding
    }
    # --cached can list files deleted from the working tree, and submodules as paths
    return @(($raw -join "`n") -split "`0" | Where-Object {
        $_ -and [System.IO.File]::Exists([System.IO.Path]::Combine($Root, $_))
    })
}

# Fallback when git isn't available or the folder isn't a repo: walk the tree
# ourselves, pruning excluded folders early and applying .gitignore files.
function Get-WalkedFileList {
    param([string]$Root, [bool]$UseGitignore)

    $rules = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push('')

    while ($stack.Count -gt 0) {
        $rel = $stack.Pop()
        $full = if ($rel) { [System.IO.Path]::Combine($Root, $rel) } else { $Root }

        if ($UseGitignore) {
            $ignoreFile = [System.IO.Path]::Combine($full, '.gitignore')
            if ([System.IO.File]::Exists($ignoreFile)) {
                foreach ($line in [System.IO.File]::ReadAllLines($ignoreFile)) {
                    $rule = ConvertFrom-GitignoreLine $line
                    if ($rule) { $rules.Add([pscustomobject]@{ Base = $rel; Rule = $rule }) }
                }
            }
        }

        try {
            $entries = [System.IO.DirectoryInfo]::new($full).GetFileSystemInfos()
        } catch {
            Write-Warning "Can't read '$full': $($_.Exception.Message)"
            continue
        }

        foreach ($entry in $entries) {
            $childRel = if ($rel) { "$rel/$($entry.Name)" } else { $entry.Name }
            if ($entry -is [System.IO.DirectoryInfo]) {
                if ($ExcludeDirs -contains $entry.Name) { continue }
                # don't follow symlinks/junctions (avoids loops)
                if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($UseGitignore -and (Test-GitIgnored $rules $childRel $true)) { continue }
                $stack.Push($childRel)
            } else {
                if ($UseGitignore -and (Test-GitIgnored $rules $childRel $false)) { continue }
                $results.Add($childRel)
            }
        }
    }
    return $results.ToArray()
}

function Test-IsBinaryFile {
    param([string]$FullPath)
    $fs = [System.IO.File]::OpenRead($FullPath)
    try {
        $buf = [byte[]]::new(8000)
        $n = $fs.Read($buf, 0, $buf.Length)
        return ([Array]::IndexOf($buf, [byte]0, 0, $n) -ge 0)
    } finally {
        $fs.Dispose()
    }
}

#endregion

$root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\', '/')
if (-not [System.IO.Directory]::Exists($root)) { throw "'$Path' is not a directory." }
$rootName = Split-Path $root -Leaf

if (-not $OutFile) { $OutFile = if ($rootName) { "./$rootName-bundle.txt" } else { './bundle.txt' } }
$outFull = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).Path $OutFile }
$outFull = [System.IO.Path]::GetFullPath($outFull)

$relPaths = $null
if (-not $NoGitignore) {
    $relPaths = Get-GitFileList -Root $root
    if ($null -ne $relPaths) { Write-Verbose 'Using git to list files (honors .gitignore).' }
}
if ($null -eq $relPaths) {
    $relPaths = Get-WalkedFileList -Root $root -UseGitignore (-not $NoGitignore)
}
$relPaths = [string[]]$relPaths
[Array]::Sort($relPaths, [System.StringComparer]::OrdinalIgnoreCase)

$bundle = [System.Text.StringBuilder]::new()
$totalOriginalChars = 0
$totalOutputChars = 0
$included = 0
$skippedBinary = 0

foreach ($rel in $relPaths) {
    $segments = $rel -split '/'
    $name = $segments[-1]

    $skip = $false
    for ($k = 0; $k -lt $segments.Count - 1; $k++) {
        if ($ExcludeDirs -contains $segments[$k]) { $skip = $true; break }
    }
    if (-not $skip) {
        foreach ($pattern in $ExcludeFiles) {
            if ($name -like $pattern) { $skip = $true; break }
        }
    }
    if ($skip) { continue }

    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $rel))
    if ([string]::Equals($full, $outFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

    $ext = [System.IO.Path]::GetExtension($name).TrimStart('.').ToLowerInvariant()
    if (($BinaryExtensions -contains $ext) -or (Test-IsBinaryFile $full)) {
        Write-Verbose "Skipping binary: $rel"
        $skippedBinary++
        continue
    }

    $original = [System.IO.File]::ReadAllText($full)
    $output = Convert-MinifiedContent -Content $original -Spec (Get-LangSpec $name) -Aggressive:$Aggressive
    if (-not $output) { continue }

    Write-Verbose "Adding: $rel"
    [void]$bundle.Append("==> $rel <==`n").Append($output).Append("`n")
    $totalOriginalChars += $original.Length
    $totalOutputChars += $output.Length
    $included++
}

if ($included -eq 0) {
    Write-Warning "No files to bundle under '$root'."
    return
}

$removed = if ($Aggressive) { 'comments, indentation, and most line breaks and spaces' } else { 'comments, blank lines and indentation' }
$preamble = "Source files from project '$rootName' ($included files). Each file starts with a '==> path <==' line. " +
    "Code has been minified to save tokens: $removed were removed " +
    "(Python indentation is kept at 1 space per level).`n"

$outDir = Split-Path $outFull -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($outFull, $preamble + $bundle.ToString(), [System.Text.UTF8Encoding]::new($false))

$pct = if ($totalOriginalChars -gt 0) { [math]::Round((1 - $totalOutputChars / $totalOriginalChars) * 100, 1) } else { 0 }
Write-Host "Bundle written to: $outFull"
Write-Host "Files included   : $included (skipped $skippedBinary binary)"
Write-Host "Size             : $totalOriginalChars -> $totalOutputChars chars ($pct% smaller, ~$([math]::Round($totalOutputChars / 4)) tokens)"
