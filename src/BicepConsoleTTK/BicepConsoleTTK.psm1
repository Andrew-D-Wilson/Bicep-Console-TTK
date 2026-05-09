function Import-Bicep {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string[]]$ImportString
    )

    begin {
        $collatedContent = [System.Text.StringBuilder]::new()
        $emittedMembers = [System.Collections.Generic.HashSet[string]]::new()
    }

    process {
        foreach ($s in $ImportString) {
            # Parse the import string
            $match = [regex]::Match($s, "[iI]mport\s+(.+)\s+from\s+'(.+)'")
            if ($match.Success) {
                $imports = $match.Groups[1].Value.Trim()
                $filePath = $match.Groups[2].Value.Trim()

                # Resolve the file path
                $resolvedPath = Resolve-Path -LiteralPath $filePath -ErrorAction SilentlyContinue
                if (-not $resolvedPath) {
                    throw "Import-Bicep: File not found: $filePath"
                }

                # Read the file content
                $content = Get-Content -Path $resolvedPath -Raw -Encoding UTF8

                # Extract the specified members
                $fileLines = $content -split '\r?\n'
                $members = if ($imports -eq '*') { $null } else {
                    $imports.Trim('{}').Split(',') | ForEach-Object { $_.Trim() }
                }

                # ── Helper: extract one member (and its leading decorators) from $fileLines.
                # Returns @{ Content = string; EndLine = int } where EndLine = -1 on failure.
                # Variables intentionally prefixed _x_ to minimise scope bleed when called with &.
                $extractOneMember = {
                    param([string[]]$_x_lines, [int]$_x_start, [int]$_x_declare, [string]$_x_type)
                    $_x_bc = 0; $_x_bk = 0; $_x_mc = ''; $_x_ei = -1
                    for ($_x_k = $_x_start; $_x_k -lt $_x_lines.Length; $_x_k++) {
                        $_x_cl = $_x_lines[$_x_k]
                        $_x_mc += $_x_cl + "`n"
                        $_x_bc += ($_x_cl.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                        $_x_bc -= ($_x_cl.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                        $_x_bk += ($_x_cl.ToCharArray() | Where-Object { $_ -eq '[' }).Count
                        $_x_bk -= ($_x_cl.ToCharArray() | Where-Object { $_ -eq ']' }).Count
                        if ($_x_bc -eq 0 -and $_x_bk -eq 0 -and $_x_k -ge $_x_declare) {
                            if ($_x_type -eq 'func' -and $_x_cl.TrimEnd().EndsWith('=>')) {
                                $_x_k++
                                while ($_x_k -lt $_x_lines.Length -and [string]::IsNullOrWhiteSpace($_x_lines[$_x_k])) { $_x_k++ }
                                $_x_fp = 0
                                while ($_x_k -lt $_x_lines.Length) {
                                    $_x_fl = $_x_lines[$_x_k]
                                    $_x_mc += $_x_fl + "`n"
                                    $_x_fp += ($_x_fl.ToCharArray() | Where-Object { $_ -eq '(' }).Count
                                    $_x_fp -= ($_x_fl.ToCharArray() | Where-Object { $_ -eq ')' }).Count
                                    $_x_nk = $_x_k + 1
                                    while ($_x_nk -lt $_x_lines.Length -and [string]::IsNullOrWhiteSpace($_x_lines[$_x_nk])) { $_x_nk++ }
                                    $_x_nt = if ($_x_nk -lt $_x_lines.Length) { $_x_lines[$_x_nk].Trim() } else { '' }
                                    if (($_x_fp -le 0) -and -not ($_x_nt.StartsWith('?') -or $_x_nt.StartsWith(':'))) { break }
                                    $_x_k++
                                }
                                $_x_ei = $_x_k; break
                            }
                            if ($_x_type -eq 'func' -and $_x_cl.Contains('=>')) { $_x_ei = $_x_k; break }
                            if ($_x_cl.Trim().EndsWith('}') -or $_x_cl.Trim().EndsWith(']') -or ($_x_cl.Trim() -eq '' -and $_x_mc.Contains('{'))) { $_x_ei = $_x_k; break }
                            if ($_x_type -eq 'var' -and -not $_x_cl.Contains('{') -and -not $_x_cl.Contains('[')) { $_x_ei = $_x_k; break }
                        }
                    }
                    return @{ Content = $_x_mc; EndLine = $_x_ei }
                }

                # ── Pre-scan: build a full index of every member in the file so we can
                # resolve dependencies when emitting. Stores { Content; EndLine } per name.
                $fileIndex = @{}
                $_pi = 0
                while ($_pi -lt $fileLines.Length) {
                    $_pm = [regex]::Match($fileLines[$_pi], '^\s*(type|func|var)\s+([a-zA-Z0-9_]+)')
                    if ($_pm.Success) {
                        $_pName = $_pm.Groups[2].Value
                        $_pType = $_pm.Groups[1].Value
                        $_pStart = $_pi
                        for ($_pj = $_pi - 1; $_pj -ge 0; $_pj--) {
                            if ($fileLines[$_pj].Trim().StartsWith('@')) { $_pStart = $_pj }
                            elseif ($fileLines[$_pj].Trim() -eq '' -or $fileLines[$_pj].Trim().StartsWith('//')) { }
                            else { break }
                        }
                        $_pExt = & $extractOneMember $fileLines $_pStart $_pi $_pType
                        if ($_pExt.EndLine -ne -1 -and -not $fileIndex.ContainsKey($_pName)) {
                            $fileIndex[$_pName] = $_pExt
                        }
                        if ($_pExt.EndLine -ne -1) { $_pi = $_pExt.EndLine }
                    }
                    $_pi++
                }

                # ── Dependency-aware emit: emits array-type dependencies before the member itself.
                # The regex captures the identifier immediately before '[', which covers:
                #   type Alias = ElementType[]      (array alias)
                #   prop: ElementType[]?            (inline array property)
                $bicepBuiltins = [System.Collections.Generic.HashSet[string]]::new(
                    [string[]]@('string', 'int', 'bool', 'object', 'array', 'any', 'null', 'true', 'false')
                )
                $emitWithDeps = $null
                $emitWithDeps = {
                    param([string]$_memberName)
                    $_mc = $fileIndex[$_memberName].Content
                    # Find types referenced in array positions and emit them first
                    [regex]::Matches($_mc, '\b([a-zA-Z][a-zA-Z0-9]*)\s*\[') |
                        ForEach-Object { $_.Groups[1].Value } |
                        Where-Object { -not $bicepBuiltins.Contains($_) -and $fileIndex.ContainsKey($_) } |
                        Select-Object -Unique |
                        ForEach-Object {
                            $_depKey = "$($resolvedPath.Path)::$_"
                            if ($emittedMembers.Add($_depKey)) {
                                & $emitWithDeps $_
                            }
                        }
                    [void]$collatedContent.Append($_mc + "`n")
                }

                # ── Main scan: emit requested members in file order, with dependencies injected first.
                $i = 0
                while ($i -lt $fileLines.Length) {
                    $line = $fileLines[$i]
                    $memberMatch = [regex]::Match($line, '^\s*(type|func|var)\s+([a-zA-Z0-9_]+)')

                    if ($memberMatch.Success) {
                        $memberType = $memberMatch.Groups[1].Value
                        $memberName = $memberMatch.Groups[2].Value

                        if ($null -eq $members -or $memberName -in $members) {
                            $memberKey = "$($resolvedPath.Path)::$memberName"
                            if ($emittedMembers.Add($memberKey)) {
                                & $emitWithDeps $memberName
                            }
                            # Advance past the member using the pre-built index
                            if ($fileIndex.ContainsKey($memberName) -and $fileIndex[$memberName].EndLine -ne -1) {
                                $i = $fileIndex[$memberName].EndLine
                            }
                        }
                    }
                    $i++
                }

                # Warn about any named members that were not found in the file
                if ($null -ne $members) {
                    foreach ($requestedMember in $members) {
                        $memberKey = "$($resolvedPath.Path)::$requestedMember"
                        if (-not $emittedMembers.Contains($memberKey)) {
                            Write-Warning "Import-Bicep: Member '$requestedMember' was not found in '$filePath'"
                        }
                    }
                }
            }
        }
    }

    end {
        return $collatedContent.ToString()
    }
}

function Invoke-BicepExpression {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [Alias('b')]
        [string]$BicepImports = '',
        [Parameter(Mandatory = $true)]
        [Alias('e')]
        [string]$Expression,
        [Parameter(Mandatory = $false)]
        [Alias('s')]
        [string[]]$SetupDeclarations = @()
    )

    process {
        # Strip all decorators - they are not valid in bicep console interactive mode
        $fullBicepImports = ($BicepImports -split '\r?\n' | Where-Object { $_ -notmatch '^\s*@' }) -join "`n"

        # Bicep console processes input line-by-line and only waits for more input when braces
        # are unbalanced. Arrow functions whose expression body starts on the next line (e.g.
        # multi-line ternaries) must be collapsed to a single line so the console sees them as
        # one complete statement. Block bodies (=> {}) are left untouched.
        $collapsedLines = [System.Collections.ArrayList]::new()
        $importLines = $fullBicepImports -split '\r?\n'
        $li = 0
        while ($li -lt $importLines.Length) {
            $importLine = $importLines[$li]
            if ($importLine.TrimEnd().EndsWith('=>')) {
                # Find the first non-blank body line
                $bodyStart = $li + 1
                while ($bodyStart -lt $importLines.Length -and [string]::IsNullOrWhiteSpace($importLines[$bodyStart])) { $bodyStart++ }
                if ($bodyStart -lt $importLines.Length -and -not $importLines[$bodyStart].Trim().StartsWith('{')) {
                    # Expression body — merge all continuation lines onto the => line.
                    # When inside an object literal ({ }), add commas between properties so
                    # the collapsed single-line form is valid Bicep (e.g. { a: 1, b: 2 }).
                    $merged = $importLine.TrimEnd()
                    $parenDepth = 0
                    $localBraceDepth = 0
                    $bi = $bodyStart
                    while ($bi -lt $importLines.Length) {
                        if ([string]::IsNullOrWhiteSpace($importLines[$bi])) { $bi++; continue }
                        $bl = $importLines[$bi].Trim()
                        # Inside an object literal, consecutive property lines need a comma separator.
                        # A property line matches: identifier: value  OR  'quoted-key': value
                        $isObjProp = $localBraceDepth -gt 0 -and
                                     ($bl -match "^([a-zA-Z_][a-zA-Z0-9_]*|'[^']*')\s*:") -and
                                     -not $merged.TrimEnd().EndsWith('{') -and
                                     -not $merged.TrimEnd().EndsWith(',')
                        if ($isObjProp) {
                            $merged += ', ' + $bl
                        } else {
                            $merged += ' ' + $bl
                        }
                        $parenDepth += ($bl.ToCharArray() | Where-Object { $_ -eq '(' }).Count
                        $parenDepth -= ($bl.ToCharArray() | Where-Object { $_ -eq ')' }).Count
                        $localBraceDepth += ($bl.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                        $localBraceDepth -= ($bl.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                        $peekIdx = $bi + 1
                        while ($peekIdx -lt $importLines.Length -and [string]::IsNullOrWhiteSpace($importLines[$peekIdx])) { $peekIdx++ }
                        $peekLine = if ($peekIdx -lt $importLines.Length) { $importLines[$peekIdx].Trim() } else { '' }
                        if (($parenDepth -le 0) -and -not ($peekLine.StartsWith('?') -or $peekLine.StartsWith(':'))) { break }
                        $bi++
                    }
                    [void]$collapsedLines.Add($merged)
                    $li = $bi + 1
                    continue
                }
            }
            [void]$collapsedLines.Add($importLine)
            $li++
        }
        $fullBicepImports = $collapsedLines -join "`n"

        # Guard: ensure bicep CLI is available
        $bicepCmd = Get-Command bicep -ErrorAction SilentlyContinue
        if (-not $bicepCmd) {
            throw "bicep CLI not found. Install from: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install"
        }

        # Start the Bicep console and pass the imports, declarations, and expression to it
        $bicepPath = $bicepCmd.Source
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = $bicepPath
        $processInfo.Arguments = "console"
        $processInfo.RedirectStandardInput = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        # Explicitly request UTF-8 for stdout/stderr so output is decoded correctly on
        # Windows PowerShell 5.1, where the default is the system OEM code page.
        $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $processInfo.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        try {
            $process.Start() | Out-Null

            $inputStream = $process.StandardInput

            # Write the imported declarations, any setup declarations, then the main expression
            $inputStream.WriteLine($fullBicepImports)
            foreach ($setup in $SetupDeclarations) {
                $inputStream.WriteLine($setup)
            }
            $inputStream.WriteLine($Expression)
            $inputStream.Close()

            $output = $process.StandardOutput.ReadToEnd()
            $stderrOutput = $process.StandardError.ReadToEnd()  # drain stderr to prevent buffer deadlock

            $completed = $process.WaitForExit(30000)  # 30-second timeout guards against a hung console
            if (-not $completed) {
                $process.Kill()
                throw "Bicep console timed out after 30 seconds evaluating: $Expression"
            }

            # Bicep console writes errors to stdout as:
            #   <offending expression echoed>
            #   ~~~~ <error message>
            $outputLines = $output -split '\r?\n'
            $errorLineIndex = ($outputLines | Select-String -Pattern '^\s*[~\^]+\s+\S').LineNumber | Select-Object -First 1
            if ($errorLineIndex) {
                $tildeLineIdx = $errorLineIndex - 1
                $cleanMessage = ($outputLines[$tildeLineIdx] -replace '^\s*[~\^]+\s*', '').Trim()
                $echoedExpr   = if ($tildeLineIdx -ge 1) { $outputLines[$tildeLineIdx - 1].Trim() } else { '' }
                throw "Bicep console error on '$echoedExpr': $cleanMessage"
            }

            # Surface any process-level stderr (e.g. crash, missing DLL) that was not expressed
            # as a bicep-format error on stdout, so it is not silently swallowed.
            if (-not [string]::IsNullOrWhiteSpace($stderrOutput)) {
                Write-Verbose "Bicep console stderr: $($stderrOutput.Trim())"
                if ([string]::IsNullOrWhiteSpace($output)) {
                    throw "Bicep console process error: $($stderrOutput.Trim())"
                }
            }

            # Return the full trimmed output (bicep console outputs the result directly to stdout)
            return $output.Trim()
        } finally {
            $process.Dispose()
        }
    }
}