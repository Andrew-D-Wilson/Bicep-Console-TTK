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

                $i = 0
                while ($i -lt $fileLines.Length) {
                    $line = $fileLines[$i]
                    $memberMatch = [regex]::Match($line, '^\s*(type|func|var)\s+([a-zA-Z0-9_]+)')

                    if ($memberMatch.Success) {
                        $memberType = $memberMatch.Groups[1].Value
                        $memberName = $memberMatch.Groups[2].Value

                        if ($null -eq $members -or $memberName -in $members) {
                                # Found a member to import. Look back for decorators.
                                $memberStartIndex = $i
                                for ($j = $i - 1; $j -ge 0; $j--) {
                                    if ($fileLines[$j].Trim().StartsWith('@')) {
                                        $memberStartIndex = $j
                                    }
                                    elseif ($fileLines[$j].Trim() -eq '' -or $fileLines[$j].Trim().StartsWith('//')) {
                                        # continue looking
                                    }
                                    else {
                                        break
                                    }
                                }
                                
                                # Now find the end of the member definition using brace counting
                                $braceCount = 0
                                $memberContent = ""
                                $endIndex = -1

                                for ($k = $memberStartIndex; $k -lt $fileLines.Length; $k++) {
                                    $currentLine = $fileLines[$k]
                                    $memberContent += $currentLine + "`n"
                                    
                                    $braceCount += ($currentLine.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                                    $braceCount -= ($currentLine.ToCharArray() | Where-Object { $_ -eq '}' }).Count
                                    
                                    # Heuristic to find the end of a declaration.
                                    # It ends if braces are balanced and the line is not just opening a block
                                    # or if it's a simple one-line var/func without braces.
                                    if ($braceCount -eq 0 -and $k -ge $i) {
                                        # Arrow func with body on the NEXT line(s): func(...) type =>
                                        # The body may span multiple lines (e.g. a multi-line ternary), so we keep
                                        # reading until parens are balanced AND the next non-blank line doesn't
                                        # start with '?' or ':' (ternary continuation).
                                        if ($memberType -eq 'func' -and $currentLine.TrimEnd().EndsWith('=>')) {
                                            $k++
                                            while ($k -lt $fileLines.Length -and [string]::IsNullOrWhiteSpace($fileLines[$k])) { $k++ }
                                            $bodyParenCount = 0
                                            while ($k -lt $fileLines.Length) {
                                                $bodyLine = $fileLines[$k]
                                                $memberContent += $bodyLine + "`n"
                                                $bodyParenCount += ($bodyLine.ToCharArray() | Where-Object { $_ -eq '(' }).Count
                                                $bodyParenCount -= ($bodyLine.ToCharArray() | Where-Object { $_ -eq ')' }).Count
                                                # Peek at the next non-blank line to see if it continues the expression
                                                $nextK = $k + 1
                                                while ($nextK -lt $fileLines.Length -and [string]::IsNullOrWhiteSpace($fileLines[$nextK])) { $nextK++ }
                                                $nextTrimmed = if ($nextK -lt $fileLines.Length) { $fileLines[$nextK].Trim() } else { '' }
                                                $isContinuation = ($bodyParenCount -gt 0) -or $nextTrimmed.StartsWith('?') -or $nextTrimmed.StartsWith(':')
                                                if (-not $isContinuation) { break }
                                                $k++
                                            }
                                            $endIndex = $k
                                            break
                                        }
                                        # Inline arrow func: func(...) type => expression
                                        if ($memberType -eq 'func' -and $currentLine.Contains('=>')) {
                                            $endIndex = $k
                                            break
                                        }
                                        # For types or funcs with bodies
                                        if ($currentLine.Trim().EndsWith('}') -or ($currentLine.Trim() -eq '' -and $memberContent.Contains('{'))) {
                                            $endIndex = $k
                                            break
                                        }
                                        # For simple var
                                        if ($memberType -eq 'var' -and -not $currentLine.Contains('{')) {
                                            $endIndex = $k
                                            break
                                        }
                                    }
                                }

                                if ($endIndex -ne -1) {
                                    $memberKey = "$($resolvedPath.Path)::$memberName"
                                    if ($emittedMembers.Add($memberKey)) {
                                        [void]$collatedContent.Append($memberContent + "`n")
                                    }
                                    $i = $endIndex # Continue scanning from after the found member
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
                    # Expression body — merge all continuation lines onto the => line
                    $merged = $importLine.TrimEnd()
                    $parenDepth = 0
                    $bi = $bodyStart
                    while ($bi -lt $importLines.Length) {
                        if ([string]::IsNullOrWhiteSpace($importLines[$bi])) { $bi++; continue }
                        $bl = $importLines[$bi].Trim()
                        $merged += ' ' + $bl
                        $parenDepth += ($bl.ToCharArray() | Where-Object { $_ -eq '(' }).Count
                        $parenDepth -= ($bl.ToCharArray() | Where-Object { $_ -eq ')' }).Count
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
            $null = $process.StandardError.ReadToEnd()  # drain stderr to prevent buffer deadlock

            $process.WaitForExit()

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

            # Return the full trimmed output (bicep console outputs the result directly to stdout)
            return $output.Trim()
        } finally {
            $process.Dispose()
        }
    }
}