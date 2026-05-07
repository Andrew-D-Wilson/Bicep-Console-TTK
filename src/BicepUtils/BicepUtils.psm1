function Import-Bicep {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string[]]$ImportString
    )

    begin {
        $collatedContent = ""
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
                    Write-Error "File not found: $filePath"
                    continue
                }

                # Read the file content
                $content = Get-Content -Path $resolvedPath -Raw

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
                                        # Arrow func with body on the NEXT line: func(...) type =>
                                        if ($memberType -eq 'func' -and $currentLine.TrimEnd().EndsWith('=>')) {
                                            $k++
                                            while ($k -lt $fileLines.Length -and [string]::IsNullOrWhiteSpace($fileLines[$k])) { $k++ }
                                            if ($k -lt $fileLines.Length) {
                                                $memberContent += $fileLines[$k] + "`n"
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
                                    $collatedContent += $memberContent + "`n"
                                    $i = $endIndex # Continue scanning from after the found member
                                }
                        }
                    }
                    $i++
                }
            }
        }
    }

    end {
        return $collatedContent
    }
}

function Invoke-BicepExpression {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [Alias('b')]
        [string]$BicepCode = '',
        [Parameter(Mandatory = $true)]
        [Alias('e')]
        [string]$Expression,
        [Parameter(Mandatory = $false)]
        [Alias('s')]
        [string[]]$SetupExpressions = @()
    )

    process {
        # Strip all decorators - they are not valid in bicep console interactive mode
        $fullBicepCode = ($BicepCode -split '\r?\n' | Where-Object { $_ -notmatch '^\s*@' }) -join "`n"

        # Start the Bicep console and pass the code to it
        $bicepPath = (Get-Command bicep).Source
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
        $process.Start() | Out-Null

        $inputStream = $process.StandardInput
        
        # Write the imported declarations, any setup expressions, then the main expression
        $inputStream.WriteLine($fullBicepCode)
        foreach ($setup in $SetupExpressions) {
            $inputStream.WriteLine($setup)
        }
        $inputStream.WriteLine($Expression)
        $inputStream.Close()

        $output = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()

        $process.WaitForExit()

        # Bicep console writes errors to stdout in the form:
        #   <expression echoed>
        #   ~~~~~ <error message>
        # Detect this by looking for a line of tildes/carets followed by an error message.
        $outputLines = $output -split '\r?\n'
        $errorLineIndex = ($outputLines | Select-String -Pattern '^\s*[~\^]+\s+\S').LineNumber | Select-Object -First 1
        if ($errorLineIndex) {
            # Grab the echoed expression and the error message for a clear failure
            $errorMessage = ($outputLines[$errorLineIndex - 1]).Trim()
            throw "Bicep console error: $errorMessage"
        }

        # Return the full trimmed output (bicep console outputs the result directly to stdout)
        return $output.Trim()
    }
}