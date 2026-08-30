#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-MetaValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = ''
    )
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
        return $prop.Value
    }
    return $Default
}

function ConvertTo-SafeFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $clean = $Name -replace '[<>:"/\\|?*]', ''
    $clean = $clean -replace '[\x00-\x1F]', ''
    $clean = ($clean -replace '\s+', ' ').Trim()
    $clean = $clean.TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'untitled' }
    return $clean
}

function Get-VideoFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Metadata)
    $channel = Get-MetaValue $Metadata 'channel' (Get-MetaValue $Metadata 'uploader' 'Unknown Channel')
    $title = Get-MetaValue $Metadata 'title' 'Untitled'
    return "$(ConvertTo-SafeFileName $channel) - $(ConvertTo-SafeFileName $title).md"
}

function ConvertTo-YamlString {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $escaped = $Value -replace '\\', '\\\\' -replace '"', '\"'
    return '"' + $escaped + '"'
}

function New-VideoMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Summary,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Transcript,
        [Parameter(Mandatory)][string]$SourceUrl
    )

    $title = Get-MetaValue $Metadata 'title' 'Untitled'
    $channel = Get-MetaValue $Metadata 'channel' (Get-MetaValue $Metadata 'uploader' 'Unknown')
    $videoId = Get-MetaValue $Metadata 'id' ''
    $description = Get-MetaValue $Metadata 'description' ''
    $uploadDate = Get-MetaValue $Metadata 'upload_date' ''

    $published = ''
    if ($uploadDate -match '^\d{8}$') {
        $published = '{0}-{1}-{2}' -f $uploadDate.Substring(0, 4), $uploadDate.Substring(4, 2), $uploadDate.Substring(6, 2)
    }
    $created = (Get-Date).ToString('yyyy-MM-dd')

    $descOneLine = ($description -replace '\s+', ' ').Trim()
    if ($descOneLine.Length -gt 200) { $descOneLine = $descOneLine.Substring(0, 200) }

    $canonicalUrl = if ($videoId) { "https://www.youtube.com/watch?v=$videoId" } else { $SourceUrl }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('title: ' + (ConvertTo-YamlString $title))
    [void]$sb.AppendLine('source: ' + (ConvertTo-YamlString $SourceUrl))
    [void]$sb.AppendLine('author:')
    [void]$sb.AppendLine('  - ' + (ConvertTo-YamlString "[[$channel]]"))
    [void]$sb.AppendLine('published: ' + $published)
    [void]$sb.AppendLine('created: ' + $created)
    [void]$sb.AppendLine('description: ' + (ConvertTo-YamlString $descOneLine))
    [void]$sb.AppendLine('tags:')
    [void]$sb.AppendLine('  - "clippings"')
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine("![]($canonicalUrl)")
    [void]$sb.AppendLine()

    if (-not [string]::IsNullOrWhiteSpace($description)) {
        foreach ($dl in ($description -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($dl)) {
                [void]$sb.AppendLine()
            }
            else {
                [void]$sb.AppendLine($dl.TrimEnd() + '  ')
            }
        }
        [void]$sb.AppendLine()
    }

    [void]$sb.AppendLine('## Summary')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine($Summary.Trim())
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Transcript')
    [void]$sb.AppendLine()
    if ([string]::IsNullOrWhiteSpace($Transcript)) {
        [void]$sb.AppendLine('_Транскрипт недоступен._')
    }
    else {
        [void]$sb.AppendLine($Transcript.Trim())
    }

    return $sb.ToString().TrimEnd() + "`n"
}

Export-ModuleMember -Function ConvertTo-SafeFileName, Get-VideoFileName, New-VideoMarkdown, Get-MetaValue
