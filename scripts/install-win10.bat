@echo off
setlocal EnableExtensions
rem ============================================================
rem  dsh-purge Windows 10 installer (one file, double-click OK)
rem
rem    install-win10.bat
rem    install-win10.bat web
rem    install-win10.bat desktop
rem    install-win10.bat both
rem    install-win10.bat web "D:\path\to\.dsh"
rem    install-win10.bat --dry-run
rem    install-win10.bat --self-test
rem
rem  Repo: https://github.com/niuniuqiu/dsh-purge.git
rem  Does not restart the host and does not click Apply.
rem ============================================================
set "DSH_PURGE_BAT=%~f0"
set "DSH_PURGE_PS1=%TEMP%\dsh-purge-install-%RANDOM%%RANDOM%.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$t=[System.IO.File]::ReadAllText($env:DSH_PURGE_BAT,(New-Object System.Text.UTF8Encoding $false)); $pats=@([string]([char]13+[char]10+'###DSH_PURGE_PS1###'+[char]13+[char]10),[string]([char]10+'###DSH_PURGE_PS1###'+[char]10)); $i=-1; $n=0; foreach($p in $pats){ $j=$t.IndexOf($p); if($j -ge 0){ $i=$j; $n=$p.Length; break } }; if($i -lt 0){ Write-Host 'marker missing'; exit 1 }; $s=$t.Substring($i+$n); [System.IO.File]::WriteAllText($env:DSH_PURGE_PS1,$s,(New-Object System.Text.UTF8Encoding $true))"
if errorlevel 1 goto :extract_fail

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%DSH_PURGE_PS1%" %*
set "EC=%ERRORLEVEL%"
del /f /q "%DSH_PURGE_PS1%" >nul 2>&1
echo.
echo Press any key to close...
pause >nul
exit /b %EC%

:extract_fail
echo Failed to prepare the installer script.
echo Press any key to close...
pause >nul
exit /b 1

###DSH_PURGE_PS1###
$ErrorActionPreference = 'Stop'
$script:GitRepo = 'https://github.com/niuniuqiu/dsh-purge.git'
$script:DepValue = 'file:../../plugins/dsh-purge'
$script:Backups = New-Object System.Collections.Generic.List[string]

function Read-TextFile([string]$Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    throw "文件是 UTF-16，未修改: $Path"
  }
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    return @{ Text = $text; Enc = 'utf8'; Bom = $true }
  }
  $strict = New-Object System.Text.UTF8Encoding $false, $true
  try {
    $text = $strict.GetString($bytes)
    return @{ Text = $text; Enc = 'utf8'; Bom = $false }
  } catch {
    $text = [System.Text.Encoding]::Default.GetString($bytes)
    return @{ Text = $text; Enc = 'ansi'; Bom = $false }
  }
}

function Write-TextFile([string]$Path, [string]$Text, $Info) {
  if ($Info.Enc -eq 'ansi') {
    $bytes = [System.Text.Encoding]::Default.GetBytes($Text)
  } else {
    $enc = New-Object System.Text.UTF8Encoding ([bool]$Info.Bom)
    $pre = $enc.GetPreamble()
    $body = $enc.GetBytes($Text)
    $bytes = New-Object byte[] ($pre.Length + $body.Length)
    if ($pre.Length -gt 0) { [Array]::Copy($pre, 0, $bytes, 0, $pre.Length) }
    if ($body.Length -gt 0) { [Array]::Copy($body, 0, $bytes, $pre.Length, $body.Length) }
  }
  [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Read-JsonString {
  param([string]$Text, [int]$QuoteIdx)
  if ($Text[$QuoteIdx] -ne '"') { throw "package.json 字符串起点不对，文件未修改" }
  $i = $QuoteIdx + 1
  $esc = $false
  $sb = New-Object System.Text.StringBuilder
  while ($i -lt $Text.Length) {
    $c = $Text[$i]
    if ($esc) {
      [void]$sb.Append($c)
      $esc = $false
      $i++
      continue
    }
    if ($c -eq '\') { $esc = $true; $i++; continue }
    if ($c -eq '"') { return @{ End = $i; Value = $sb.ToString() } }
    [void]$sb.Append($c)
    $i++
  }
  throw "package.json 字符串没有结束引号，文件未修改"
}

function Skip-Ws([string]$Text, [int]$Index, [int]$Limit) {
  $i = $Index
  while ($i -lt $Limit -and [char]::IsWhiteSpace($Text[$i])) { $i++ }
  return $i
}

function Get-ContainerEnd {
  param([string]$Text, [int]$OpenIdx)
  $openCh = $Text[$OpenIdx]
  $closeCh = ''
  if ($openCh -eq '{') { $closeCh = '}' }
  elseif ($openCh -eq '[') { $closeCh = ']' }
  else { throw "package.json 括号起点不对，文件未修改" }
  $depth = 0
  $i = $OpenIdx
  while ($i -lt $Text.Length) {
    $c = $Text[$i]
    if ($c -eq '"') {
      $str = Read-JsonString -Text $Text -QuoteIdx $i
      $i = $str.End + 1
      continue
    }
    if ($c -eq $openCh) { $depth++ }
    elseif ($c -eq $closeCh) {
      $depth--
      if ($depth -eq 0) { return $i }
    }
    $i++
  }
  throw "package.json 括号不配对，文件未修改"
}

function Find-RootOpen([string]$Text) {
  $i = Skip-Ws $Text 0 $Text.Length
  if ($i -ge $Text.Length -or $Text[$i] -ne '{') { throw "package.json 不是以 { 开头，文件未修改" }
  return $i
}

function Find-PropertyValueStart {
  param([string]$Text, [int]$ObjOpen, [string]$Key)
  if ($Text[$ObjOpen] -ne '{') { throw "内部错误: 不是对象" }
  $objEnd = Get-ContainerEnd -Text $Text -OpenIdx $ObjOpen
  $i = $ObjOpen + 1
  $depth = 1
  while ($i -lt $objEnd) {
    $c = $Text[$i]
    if ($c -eq '"') {
      $str = Read-JsonString -Text $Text -QuoteIdx $i
      $i = $str.End + 1
      if ($depth -eq 1) {
        $j = Skip-Ws $Text $i $objEnd
        if ($j -lt $objEnd -and $Text[$j] -eq ':') {
          if ($str.Value -eq $Key) {
            $j++
            return (Skip-Ws $Text $j $objEnd)
          }
        }
      }
      continue
    }
    if ($c -eq '{' -or $c -eq '[') { $depth++; $i++; continue }
    if ($c -eq '}' -or $c -eq ']') { $depth--; $i++; continue }
    $i++
  }
  return -1
}

function Insert-BeforeContainerEnd {
  param([string]$Text, [int]$OpenIdx, [string]$Token)
  $closeIdx = Get-ContainerEnd -Text $Text -OpenIdx $OpenIdx
  $nl = "`n"
  if ($Text.Contains("`r`n")) { $nl = "`r`n" }
  $innerEmpty = $true
  for ($k = $OpenIdx + 1; $k -lt $closeIdx; $k++) {
    if (-not [char]::IsWhiteSpace($Text[$k])) { $innerEmpty = $false; break }
  }
  $lineStart = $Text.LastIndexOf([char]10, $closeIdx)
  if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart++ }
  $baseIndent = ''
  for ($k = $lineStart; $k -lt $closeIdx; $k++) {
    $ch = $Text[$k]
    if ($ch -eq ' ' -or $ch -eq "`t") { $baseIndent += $ch } else { break }
  }
  if ($innerEmpty) {
    $itemIndent = $baseIndent + '  '
    $ins = $nl + $itemIndent + $Token + $nl + $baseIndent
    return $Text.Substring(0, $OpenIdx + 1) + $ins + $Text.Substring($closeIdx)
  }
  $i = $closeIdx - 1
  while ($i -gt $OpenIdx -and [char]::IsWhiteSpace($Text[$i])) { $i-- }
  $itemIndent = ''
  $lastNl = $Text.LastIndexOf([char]10, $i)
  if ($lastNl -lt 0) {
    $itemIndent = '  '
  } else {
    for ($k = $lastNl + 1; $k -le $i; $k++) {
      $ch = $Text[$k]
      if ($ch -eq ' ' -or $ch -eq "`t") { $itemIndent += $ch } else { break }
    }
    if ($itemIndent.Length -eq 0) { $itemIndent = $baseIndent + '  ' }
  }
  $needsComma = ($Text[$i] -ne ',') -and ($Text[$i] -ne $Text[$OpenIdx])
  $comma = ''
  if ($needsComma) { $comma = ',' }
  $ins = $comma + $nl + $itemIndent + $Token
  return $Text.Substring(0, $i + 1) + $ins + $Text.Substring($i + 1)
}

function Get-DepMap($Obj) {
  $map = @{}
  if ($null -eq $Obj) { return $map }
  foreach ($p in $Obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
  return $map
}

function Get-BundleList($Json) {
  $items = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Json.dsh -or $null -eq $Json.dsh.profile) { throw "缺少 dsh.profile，已放弃写入" }
  $raw = $Json.dsh.profile.bundles
  if ($null -ne $raw) {
    foreach ($b in @($raw)) {
      if ($null -ne $b) { [void]$items.Add([string]$b) }
    }
  }
  # 逐个输出，避免 PowerShell 把单个元素拆成字符串
  foreach ($b in $items) { Write-Output $b }
}

function Get-Reload($Json) {
  if ($null -eq $Json.dsh -or $null -eq $Json.dsh.profile) { return $null }
  $p = $Json.dsh.profile.PSObject.Properties['patchReload']
  if ($null -eq $p) { return $null }
  return [string]$p.Value
}

function Assert-SameProp($Before, $After, [string]$Name) {
  $b = $Before.PSObject.Properties[$Name]
  $a = $After.PSObject.Properties[$Name]
  $bMissing = ($null -eq $b)
  $aMissing = ($null -eq $a)
  if ($bMissing -ne $aMissing) { throw "$Name 被改动，已放弃写入" }
  if (-not $bMissing -and [string]$b.Value -ne [string]$a.Value) { throw "$Name 被改动，已放弃写入" }
}

function Assert-Invariants($Before, $After) {
  Assert-SameProp $Before $After 'name'
  Assert-SameProp $Before $After 'version'
  Assert-SameProp $Before $After 'private'
  Assert-SameProp $Before $After 'description'
  $br = Get-Reload $Before
  $ar = Get-Reload $After
  if ($br -ne $ar) { throw "patchReload 被改动，已放弃写入" }

  $bc = @($Before.PSObject.Properties).Count
  $ac = @($After.PSObject.Properties).Count
  $hadDeps = $null -ne $Before.PSObject.Properties['dependencies']
  if ($hadDeps) {
    if ($ac -ne $bc) { throw "顶层字段数量变了，已放弃写入" }
  } elseif ($ac -ne ($bc + 1)) {
    throw "顶层字段数量不对，已放弃写入"
  }

  $bd = Get-DepMap $Before.dependencies
  $ad = Get-DepMap $After.dependencies
  foreach ($k in @($bd.Keys)) {
    if ($k -eq 'dsh-purge') { continue }
    if (-not $ad.ContainsKey($k)) { throw "依赖 $k 丢失，已放弃写入" }
    if ([string]$bd[$k] -ne [string]$ad[$k]) { throw "依赖 $k 被改动，已放弃写入" }
  }
  foreach ($k in @($ad.Keys)) {
    if ($k -eq 'dsh-purge') { continue }
    if (-not $bd.ContainsKey($k)) { throw "多出依赖 $k，已放弃写入" }
  }
  if (-not $ad.ContainsKey('dsh-purge')) { throw "没有写入 dependencies.dsh-purge，已放弃写入" }
  if ([string]$ad['dsh-purge'] -ne $script:DepValue) { throw "dsh-purge 不是 file:../../plugins/dsh-purge，已放弃写入" }

  $bb = @(Get-BundleList $Before)
  $ab = @(Get-BundleList $After)
  $had = $false
  foreach ($b in $bb) { if ($b -eq 'dsh-purge') { $had = $true } }
  if ($had) {
    if ($bb.Count -ne $ab.Count) { throw "bundles 数量变了，已放弃写入" }
    for ($n = 0; $n -lt $bb.Count; $n++) {
      if ([string]$bb[$n] -ne [string]$ab[$n]) { throw "bundles 被改动，已放弃写入" }
    }
  } else {
    if ($ab.Count -ne ($bb.Count + 1)) { throw "bundles 追加结果不对，已放弃写入" }
    for ($n = 0; $n -lt $bb.Count; $n++) {
      if ([string]$bb[$n] -ne [string]$ab[$n]) { throw "原有 bundle 被改动，已放弃写入" }
    }
    if ([string]$ab[$ab.Count - 1] -ne 'dsh-purge') { throw "dsh-purge 没有加在 bundles 末尾，已放弃写入" }
  }
}

function Update-ProfileText([string]$Text) {
  try { $before = $Text | ConvertFrom-Json } catch { throw "package.json 无法解析，文件未修改" }
  if ($script:DepValue -ne 'file:../../plugins/dsh-purge') { throw "内部错误: 依赖路径不对" }
  $root = Find-RootOpen $Text
  $literal = '"' + $script:DepValue + '"'

  $depIdx = Find-PropertyValueStart -Text $Text -ObjOpen $root -Key 'dependencies'
  if ($depIdx -lt 0) {
    $Text = Insert-BeforeContainerEnd -Text $Text -OpenIdx $root -Token ('"dependencies": { "dsh-purge": ' + $literal + ' }')
  } else {
    if ($Text[$depIdx] -ne '{') { throw "dependencies 不是对象，文件未修改" }
    $exist = Find-PropertyValueStart -Text $Text -ObjOpen $depIdx -Key 'dsh-purge'
    if ($exist -lt 0) {
      $Text = Insert-BeforeContainerEnd -Text $Text -OpenIdx $depIdx -Token ('"dsh-purge": ' + $literal)
    } else {
      if ($Text[$exist] -ne '"') { throw "dependencies.dsh-purge 不是字符串，文件未修改" }
      $str = Read-JsonString -Text $Text -QuoteIdx $exist
      $curLit = $Text.Substring($exist, $str.End - $exist + 1)
      $curVal = $curLit | ConvertFrom-Json
      if ([string]$curVal -ne $script:DepValue) {
        $Text = $Text.Substring(0, $exist) + $literal + $Text.Substring($str.End + 1)
      }
    }
  }

  $root = Find-RootOpen $Text
  $dshIdx = Find-PropertyValueStart -Text $Text -ObjOpen $root -Key 'dsh'
  if ($dshIdx -lt 0 -or $Text[$dshIdx] -ne '{') { throw "缺少 dsh 对象，文件未修改" }
  $profIdx = Find-PropertyValueStart -Text $Text -ObjOpen $dshIdx -Key 'profile'
  if ($profIdx -lt 0 -or $Text[$profIdx] -ne '{') { throw "缺少 dsh.profile，文件未修改" }
  $bunIdx = Find-PropertyValueStart -Text $Text -ObjOpen $profIdx -Key 'bundles'
  if ($bunIdx -lt 0 -or $Text[$bunIdx] -ne '[') { throw "缺少 dsh.profile.bundles 数组，文件未修改" }

  try { $mid = $Text | ConvertFrom-Json } catch { throw "修改 dependencies 后 JSON 无法解析，已放弃写入" }
  $has = $false
  $rawBundles = $mid.dsh.profile.bundles
  if ($null -ne $rawBundles) {
    foreach ($b in @($rawBundles)) {
      if ([string]$b -eq 'dsh-purge') { $has = $true }
    }
  }
  if (-not $has) {
    $Text = Insert-BeforeContainerEnd -Text $Text -OpenIdx $bunIdx -Token '"dsh-purge"'
  }

  try { $after = $Text | ConvertFrom-Json } catch { throw "修改后的 JSON 无法解析，已放弃写入" }
  Assert-Invariants $before $after
  return $Text
}

function Update-ProfileFile([string]$Path, [bool]$DryRun) {
  $info = Read-TextFile $Path
  $old = $info.Text
  $new = Update-ProfileText $old
  if ($new -eq $old) {
    Write-Host "      已有 dsh-purge，package.json 不改"
    return
  }
  if ($DryRun) {
    Write-Host "      [dry-run] 将追加 dependencies 与 bundles 里缺少的 dsh-purge，不写文件"
    return
  }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bak = "$Path.bak-dsh-purge-$stamp"
  $tmp = "$Path.tmp-dsh-purge"
  try {
    Write-TextFile -Path $tmp -Text $new -Info $info
    $back = (Read-TextFile $tmp).Text
    if ($back -ne $new) { throw "临时文件读回不一致" }
    Copy-Item -LiteralPath $Path -Destination $bak -Force
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    throw
  }
  [void]$script:Backups.Add($bak)
  Write-Host "      已写入，并备份到"
  Write-Host "      $bak"
}

function Add-UniqueDir($List, [string]$Dir) {
  if (-not $Dir) { return }
  $Dir = $Dir.Trim().TrimEnd('\')
  if (-not $Dir) { return }
  if ($Dir -match '^[A-Za-z]:$') { return }
  $leaf = Split-Path -Leaf $Dir
  if ($leaf -eq 'Windows' -or $leaf -eq 'Program Files' -or $leaf -eq 'Program Files (x86)' -or $leaf -eq 'Users') { return }
  foreach ($e in @($List)) {
    if ([string]$e -and ([string]$e).Equals($Dir, [StringComparison]::OrdinalIgnoreCase)) { return }
  }
  [void]$List.Add($Dir)
}

function Get-SearchDirs([string]$DshSource) {
  $dirs = New-Object System.Collections.Generic.List[string]
  if ($DshSource) {
    $d = Split-Path -Parent $DshSource
    for ($n = 0; $n -lt 3 -and $d; $n++) {
      Add-UniqueDir $dirs $d
      $parent = Split-Path -Parent $d
      if (-not $parent -or $parent -eq $d) { break }
      $d = $parent
    }
  }
  if ($env:LOCALAPPDATA) { Add-UniqueDir $dirs (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness') }
  if ($env:APPDATA) { Add-UniqueDir $dirs (Join-Path $env:APPDATA 'DeepSeek Harness') }
  return $dirs
}

function Find-RelativeFile([string]$DshSource, [string[]]$RelativeNames) {
  $dirs = Get-SearchDirs $DshSource
  foreach ($d in @($dirs)) {
    foreach ($rel in $RelativeNames) {
      $p = Join-Path $d $rel
      if (Test-Path -LiteralPath $p) { return $p }
    }
  }
  return $null
}

function Sync-PathFromRegistry {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $seen = @{}
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($chunk in @($env:Path, $machine, $user)) {
    if (-not $chunk) { continue }
    foreach ($p in ($chunk -split ';')) {
      if (-not $p) { continue }
      $trim = $p.Trim()
      if (-not $trim) { continue }
      $key = $trim.ToLower()
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      [void]$parts.Add($trim)
    }
  }
  $env:Path = ($parts -join ';')
}

function Find-Git {
  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
  $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  foreach ($p in @(
    (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
    $(if ($pf86) { Join-Path $pf86 'Git\cmd\git.exe' }),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
  )) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

function Find-Node([string]$DshSource) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
  return Find-RelativeFile $DshSource @(
    'node.exe',
    'node\node.exe',
    'nodejs\node.exe',
    'runtime\node.exe',
    'bin\node.exe',
    'resources\node\node.exe'
  )
}

function Find-Pnpm([string]$DshSource) {
  $cmd = Get-Command pnpm -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) {
    return @{ Exe = $cmd.Source; Prefix = @(); Label = $cmd.Source }
  }
  foreach ($p in @(
    $(if ($env:APPDATA) { Join-Path $env:APPDATA 'npm\pnpm.cmd' }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'pnpm\pnpm.cmd' }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'pnpm\bin\pnpm.cmd' }),
    $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'scoop\shims\pnpm.cmd' })
  )) {
    if ($p -and (Test-Path -LiteralPath $p)) { return @{ Exe = $p; Prefix = @(); Label = $p } }
  }
  $near = Find-RelativeFile $DshSource @(
    'pnpm.cmd', 'pnpm.exe',
    'node\pnpm.cmd', 'nodejs\pnpm.cmd', 'runtime\pnpm.cmd', 'bin\pnpm.cmd',
    'resources\node\pnpm.cmd', 'resources\pnpm.cmd'
  )
  if ($near) { return @{ Exe = $near; Prefix = @(); Label = $near } }

  $core = Get-Command corepack -ErrorAction SilentlyContinue
  if ($core -and $core.Source -and (Test-Path -LiteralPath $core.Source)) {
    return @{ Exe = $core.Source; Prefix = @('pnpm'); Label = ($core.Source + ' pnpm') }
  }
  $node = Find-Node $DshSource
  if ($node) {
    $nodeDir = Split-Path -Parent $node
    $coreCmd = Join-Path $nodeDir 'corepack.cmd'
    if (Test-Path -LiteralPath $coreCmd) {
      return @{ Exe = $coreCmd; Prefix = @('pnpm'); Label = ($coreCmd + ' pnpm') }
    }
    foreach ($rel in @(
      'node_modules\corepack\dist\corepack.js',
      'node_modules\corepack\corepack.js'
    )) {
      $js = Join-Path $nodeDir $rel
      if (Test-Path -LiteralPath $js) {
        return @{ Exe = $node; Prefix = @($js, 'pnpm'); Label = ("node " + $js + " pnpm") }
      }
    }
  }
  $npx = Get-Command npx -ErrorAction SilentlyContinue
  if ($npx -and $npx.Source -and (Test-Path -LiteralPath $npx.Source)) {
    return @{ Exe = $npx.Source; Prefix = @('--yes', 'pnpm'); Label = ($npx.Source + ' --yes pnpm') }
  }
  return $null
}

function Add-PathFront([string]$Dir) {
  if (-not $Dir) { return }
  if (-not (Test-Path -LiteralPath $Dir)) { return }
  $env:Path = $Dir + ';' + $env:Path
}

function Invoke-PnpmInstall([string]$Dir, [string]$DshSource, [bool]$DryRun) {
  $found = Find-Pnpm $DshSource
  if (-not $found) {
    throw "找不到 pnpm。package.json 若已改好，请在该目录手动执行 pnpm install：`n  $Dir`n成功标志是 node_modules\dsh-purge\package.json 。也可以用官方 dsh 自带的 Node / pnpm 后再运行本脚本。"
  }
  $node = Find-Node $DshSource
  if ($node) { Add-PathFront (Split-Path -Parent $node) }
  Write-Host "      使用 $($found.Label)"
  if ($DryRun) {
    Write-Host "      [dry-run] 不执行 pnpm install"
    return
  }
  $argList = New-Object System.Collections.Generic.List[string]
  foreach ($a in @($found.Prefix)) { if ($null -ne $a -and "$a" -ne '') { [void]$argList.Add([string]$a) } }
  [void]$argList.Add('install')
  $invokeArgs = @($argList.ToArray())
  Push-Location -LiteralPath $Dir
  try {
    $cwd = [System.IO.Path]::GetFullPath((Get-Location).ProviderPath).TrimEnd('\')
    $want = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\')
    if (-not $cwd.Equals($want, [StringComparison]::OrdinalIgnoreCase)) { throw "工作目录不对: $cwd" }
    Write-Host "      开始 pnpm install，可能要几分钟"
    & $found.Exe @invokeArgs
    if ($LASTEXITCODE -ne 0) {
      throw "pnpm install 失败，退出码 $LASTEXITCODE 。package.json 已改好，可在此目录重试： $Dir"
    }
  } finally {
    Pop-Location
  }
}

function Assert-PluginDest([string]$Dest) {
  $leaf = Split-Path -Leaf $Dest
  if ($leaf -ne 'dsh-purge') { throw "拒绝操作意外目录: $Dest" }
  if ($Dest -notmatch '\\plugins\\dsh-purge$') { throw "插件路径必须是 plugins\dsh-purge ： $Dest" }
}

function Assert-PluginPackage([string]$Dest) {
  $pj = Join-Path $Dest 'package.json'
  if (-not (Test-Path -LiteralPath $pj)) { throw "插件目录缺少 package.json: $Dest" }
  $obj = (Read-TextFile $pj).Text | ConvertFrom-Json
  if ($obj.name -ne 'dsh-purge') { throw "插件 package.json 的 name 是 $($obj.name)，必须是 dsh-purge。目录: $Dest" }
}

function Save-Url([string]$Url, [string]$OutFile) {
  $old = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 180 -Headers @{ 'User-Agent' = 'dsh-purge-win10-install' }
  } finally {
    $ProgressPreference = $old
  }
}

function Install-PluginFromArchive([string]$Dest) {
  Assert-PluginDest $Dest
  $repoWeb = $script:GitRepo -replace '\.git$', ''
  $urls = @(
    "$repoWeb/archive/refs/heads/master.tar.gz",
    "$repoWeb/archive/refs/heads/main.tar.gz",
    "$repoWeb/archive/refs/heads/master.zip",
    "$repoWeb/archive/refs/heads/main.zip"
  )
  $work = Join-Path $env:TEMP ("dsh-purge-dl-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $archive = $null
    foreach ($u in $urls) {
      $out = Join-Path $work (Split-Path -Leaf $u)
      Write-Host "      下载 $u"
      try {
        Save-Url $u $out
        if ((Get-Item -LiteralPath $out).Length -gt 200) { $archive = $out; break }
      } catch {
        Write-Host "      这次失败: $($_.Exception.Message)"
      }
    }
    if (-not $archive) { throw "git clone 和压缩包下载都失败了" }
    $extract = Join-Path $work 'extract'
    New-Item -ItemType Directory -Path $extract | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { throw "找不到 tar.exe，无法解压" }
    & $tar -xf $archive -C $extract
    if ($LASTEXITCODE -ne 0) { throw "解压失败，退出码 $LASTEXITCODE" }
    $found = $null
    foreach ($d in @(Get-ChildItem -LiteralPath $extract -Directory)) {
      $pj = Join-Path $d.FullName 'package.json'
      if (-not (Test-Path -LiteralPath $pj)) { continue }
      $obj = (Read-TextFile $pj).Text | ConvertFrom-Json
      if ($obj.name -eq 'dsh-purge') { $found = $d.FullName; break }
    }
    if (-not $found) { throw "压缩包里没有 name 为 dsh-purge 的目录" }
    $parent = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    Move-Item -LiteralPath $found -Destination $Dest
  } finally {
    if (Test-Path -LiteralPath $work) {
      Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Install-PluginFresh([string]$Dest) {
  Assert-PluginDest $Dest
  $parent = Split-Path -Parent $Dest
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
  if (Test-Path -LiteralPath $Dest) { throw "目标已存在: $Dest" }
  $git = Find-Git
  $ok = $false
  if ($git) {
    Write-Host "      git clone --depth 1 $script:GitRepo"
    & $git clone --depth 1 $script:GitRepo $Dest
    if ($LASTEXITCODE -eq 0) { $ok = $true }
    else { Write-Host "      git clone 失败，改为下载压缩包。" }
  } else {
    Write-Host "      找不到 git，改为下载压缩包。"
  }
  if (-not $ok) {
    if ((Split-Path -Leaf $Dest) -eq 'dsh-purge' -and (Test-Path -LiteralPath $Dest)) {
      Remove-Item -LiteralPath $Dest -Recurse -Force
    }
    Install-PluginFromArchive $Dest
  }
  Assert-PluginPackage $Dest
}

function Get-NormalizedUrl([string]$Url) {
  if (-not $Url) { return '' }
  $u = $Url.Trim().TrimEnd('/')
  $u = $u -replace '\.git$', ''
  $u = $u -replace '^git@github.com:', 'https://github.com/'
  return $u.ToLower()
}

function Sync-Plugin([string]$Dest, [bool]$DryRun) {
  Assert-PluginDest $Dest
  if (-not (Test-Path -LiteralPath $Dest)) {
    if ($DryRun) {
      Write-Host "      [dry-run] 将克隆到 $Dest"
      Write-Host "      $script:GitRepo"
      return
    }
    Install-PluginFresh $Dest
    Write-Host "      插件已放到 $Dest"
    return
  }
  $pj = Join-Path $Dest 'package.json'
  if (-not (Test-Path -LiteralPath $pj)) {
    throw "已有目录但没有 package.json，请先移走再运行： $Dest"
  }
  $obj = (Read-TextFile $pj).Text | ConvertFrom-Json
  if ($obj.name -ne 'dsh-purge') {
    throw "已有目录的 name 是 $($obj.name)，不是 dsh-purge。请移走后再运行： $Dest"
  }
  $gitDir = Join-Path $Dest '.git'
  if (-not (Test-Path -LiteralPath $gitDir)) {
    Write-Host "      插件目录已在，且不是 git 仓库，保留现有文件"
    return
  }
  $git = Find-Git
  if (-not $git) {
    Write-Host "      插件目录已在，但找不到 git，跳过更新"
    return
  }
  $remote = ''
  $remote = & $git -C $Dest remote get-url origin 2>$null
  if ($LASTEXITCODE -ne 0) { $remote = '' }
  $want = Get-NormalizedUrl $script:GitRepo
  $have = Get-NormalizedUrl $remote
  if ($have -eq $want) {
    if ($DryRun) {
      Write-Host "      [dry-run] 将 git pull --ff-only"
      return
    }
    Write-Host "      git pull --ff-only"
    & $git -C $Dest pull --ff-only
    if ($LASTEXITCODE -ne 0) {
      Write-Host "      git pull 失败，继续使用当前文件"
    }
    Assert-PluginPackage $Dest
    return
  }
  Write-Host "      现有远程: $remote"
  Write-Host "      本次要装: $script:GitRepo"
  if ($DryRun) {
    Write-Host "      [dry-run] 正式运行时会询问是否备份旧目录并重新克隆"
    return
  }
  $ans = Read-Host "      输入 Y 备份旧目录并重新克隆，其它键保留现有目录"
  if ($ans -eq 'Y' -or $ans -eq 'y') {
    $bak = $Dest + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Move-Item -LiteralPath $Dest -Destination $bak
    Write-Host "      旧目录已改名为 $bak"
    Install-PluginFresh $Dest
  } else {
    Write-Host "      保留现有插件目录"
  }
  Assert-PluginPackage $Dest
}

function Test-HomeLayout([string]$Path) {
  $profiles = Join-Path $Path 'profiles'
  if (-not (Test-Path -LiteralPath $profiles)) { return '没有 profiles 目录' }
  $any = $false
  $dirs = Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue
  foreach ($d in @($dirs)) {
    if (Test-Path -LiteralPath (Join-Path $d.FullName 'package.json')) { $any = $true; break }
  }
  if (-not $any) { return 'profiles 下没有 package.json' }
  return ''
}

function Add-HomeCandidate($Checked, $Valid, [string]$Path, [string]$Reason) {
  if (-not $Path) { return }
  $Path = $Path.Trim().Trim('"').TrimEnd('\')
  if (-not $Path) { return }
  foreach ($c in @($Checked)) {
    if ($c.Path.Equals($Path, [StringComparison]::OrdinalIgnoreCase)) { return }
  }
  $note = Test-HomeLayout $Path
  $ok = ($note -eq '')
  if ($ok) { $note = '可用' }
  $item = @{ Path = $Path; Reason = $Reason; Ok = $ok; Note = $note }
  [void]$Checked.Add($item)
  if ($ok) { [void]$Valid.Add($item) }
}

function Get-HomeCandidates {
  $checked = New-Object System.Collections.Generic.List[object]
  $valid = New-Object System.Collections.Generic.List[object]
  if ($env:DSH_HOME) {
    $before = $checked.Count
    Add-HomeCandidate $checked $valid $env:DSH_HOME '环境变量 DSH_HOME'
    if ($checked.Count -gt $before) {
      $envItem = $checked[$checked.Count - 1]
      if (-not $envItem.Ok) {
        Write-Host "环境变量 DSH_HOME 不能用: $($envItem.Path) （$($envItem.Note)），继续找其它位置"
      }
    }
  }
  $dsh = Get-Command dsh -ErrorAction SilentlyContinue
  $script:DshSource = $null
  if ($dsh -and $dsh.Source) { $script:DshSource = $dsh.Source }
  if ($script:DshSource) {
    $dir = Split-Path -Parent $script:DshSource
    Add-HomeCandidate $checked $valid (Join-Path $dir '.dsh') 'dsh 所在目录旁的 .dsh'
    $p1 = Split-Path -Parent $dir
    if ($p1) { Add-HomeCandidate $checked $valid (Join-Path $p1 '.dsh') 'dsh 上一级旁的 .dsh' }
    $p2 = $null
    if ($p1) { $p2 = Split-Path -Parent $p1 }
    if ($p2) { Add-HomeCandidate $checked $valid (Join-Path $p2 '.dsh') 'dsh 上两级旁的 .dsh' }
  }
  if ($env:USERPROFILE) {
    Add-HomeCandidate $checked $valid (Join-Path $env:USERPROFILE '.dsh') '用户目录 .dsh'
  }
  if ($env:APPDATA) {
    Add-HomeCandidate $checked $valid (Join-Path $env:APPDATA 'DeepSeek Harness\dsh-home') 'APPDATA dsh-home'
  }
  if ($env:LOCALAPPDATA) {
    Add-HomeCandidate $checked $valid (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness\dsh-home') 'LOCALAPPDATA dsh-home'
  }
  return @{ Checked = $checked; Valid = $valid }
}

function Get-ProfileStatus([string]$DshHome) {
  $result = New-Object System.Collections.Generic.List[object]
  foreach ($name in @('web', 'desktop')) {
    $dir = Join-Path $DshHome ("profiles\" + $name)
    $pkg = Join-Path $dir 'package.json'
    $st = @{ Name = $name; Dir = $dir; Pkg = $pkg; Ok = $false; Reason = '' }
    if (-not (Test-Path -LiteralPath $pkg)) {
      $st.Reason = '没有 package.json'
      [void]$result.Add($st)
      continue
    }
    try {
      $obj = (Read-TextFile $pkg).Text | ConvertFrom-Json
    } catch {
      $st.Reason = 'package.json 无法解析'
      [void]$result.Add($st)
      continue
    }
    $expect = 'dsh-profile-desktop'
    if ($name -eq 'web') { $expect = 'dsh-profile-web' }
    if ($obj.name -ne $expect) {
      $st.Reason = "name 是 $($obj.name)，期望 $expect"
      [void]$result.Add($st)
      continue
    }
    $st.Ok = $true
    $st.Reason = $expect
    [void]$result.Add($st)
  }
  return $result.ToArray()
}

function Read-Choice([string]$Prompt, [string[]]$Valid) {
  while ($true) {
    $ans = Read-Host $Prompt
    if ($null -eq $ans) { throw "已取消" }
    $ans = $ans.Trim()
    if ($ans -eq 'q' -or $ans -eq 'Q') { throw "已取消" }
    foreach ($v in $Valid) {
      if ($ans -eq $v) { return $v }
    }
    Write-Host "      请输入 $($Valid -join ' / ')，或 q 退出"
  }
}

function Show-ManualSteps([string]$DshHome, $Names) {
  Write-Host ""
  Write-Host "文件已经放好。下面这些脚本不会代做:"
  Write-Host "  1. 完全退出刚装的那个宿主，再打开。"
  foreach ($n in @($Names)) {
    if ($n -eq 'web') { Write-Host "     Web: 关掉 dsh web 再开。" }
    if ($n -eq 'desktop') { Write-Host "     桌面: 退出托盘，再打开对应 exe。" }
  }
  Write-Host "  2. 在这个宿主里点会话标题旁的 dsh-purge，进入「清洗」，点「应用」。"
  Write-Host "     宿主的设置页里没有这个按钮。"
  Write-Host "  3. 「应用」成功后会自动重启一次。没点「应用」不会重启。"
  Write-Host "本次改的是: $($Names -join ', ')"
  Write-Host "DSH_HOME:"
  Write-Host "  $DshHome"
}

function Show-Usage {
  Write-Host "用法:"
  Write-Host "  install-win10.bat"
  Write-Host "  install-win10.bat web"
  Write-Host "  install-win10.bat desktop"
  Write-Host "  install-win10.bat both"
  Write-Host "  install-win10.bat web `"D:\path\to\.dsh`""
  Write-Host "  install-win10.bat --dry-run"
  Write-Host "  install-win10.bat --self-test"
  Write-Host "仓库: $script:GitRepo"
  Write-Host "只改你选中的 profile。不点「应用」，也不重启宿主。"
}

function Invoke-SelfTest {
  if ($script:GitRepo -ne 'https://github.com/niuniuqiu/dsh-purge.git') { throw "自检: 仓库地址不对" }
  if ($script:DepValue -ne 'file:../../plugins/dsh-purge') { throw "自检: 依赖路径不对" }

  $nl = "`r`n"
  $pretty = '{' + $nl
  $pretty += '  "name": "dsh-profile-web",' + $nl
  $pretty += '  "description": "保持中文",' + $nl
  $pretty += '  "private": true,' + $nl
  $pretty += '  "version": "1.2.3",' + $nl
  $pretty += '  "dependencies": {' + $nl
  $pretty += '    "@deepseek-ai/dsh-base": "1.0.0",' + $nl
  $pretty += '    "@deepseek-ai/dsh-web-app": "1.0.0"' + $nl
  $pretty += '  },' + $nl
  $pretty += '  "dsh": {' + $nl
  $pretty += '    "profile": {' + $nl
  $pretty += '      "bundles": [' + $nl
  $pretty += '        "@deepseek-ai/dsh-base",' + $nl
  $pretty += '        "@deepseek-ai/dsh-web-app"' + $nl
  $pretty += '      ],' + $nl
  $pretty += '      "patchReload": "live"' + $nl
  $pretty += '    }' + $nl
  $pretty += '  }' + $nl
  $pretty += '}' + $nl
  $once = Update-ProfileText $pretty
  $twice = Update-ProfileText $once
  if ($twice -ne $once) { throw "自检: 第二次运行不应再改 package.json" }
  if ($once -notlike '*保持中文*') { throw "自检: 中文丢失" }
  if ($once -notlike '*"patchReload": "live"*') { throw "自检: patchReload 被改写" }
  if ($once -notlike '*"version": "1.2.3"*') { throw "自检: version 被改写" }
  if ($once -notlike '*"@deepseek-ai/dsh-web-app": "1.0.0"*') { throw "自检: 原依赖被改" }
  $obj = $once | ConvertFrom-Json
  if ([string]$obj.dependencies.'dsh-purge' -ne $script:DepValue) { throw "自检: 依赖路径不对" }
  $bundles = @(Get-BundleList $obj)
  if ($bundles.Count -ne 3 -or [string]$bundles[2] -ne 'dsh-purge') { throw "自检: bundle 没有加在末尾" }

  $desk = '{' + $nl
  $desk += '  "name": "dsh-profile-desktop",' + $nl
  $desk += '  "dependencies": {' + $nl
  $desk += '    "@deepseek-ai/dsh-base": "2.0.0"' + $nl
  $desk += '  },' + $nl
  $desk += '  "dsh": {' + $nl
  $desk += '    "profile": {' + $nl
  $desk += '      "bundles": [' + $nl
  $desk += '        "@deepseek-ai/dsh-base"' + $nl
  $desk += '      ],' + $nl
  $desk += '      "patchReload": "live"' + $nl
  $desk += '    }' + $nl
  $desk += '  }' + $nl
  $desk += '}' + $nl
  $dout = Update-ProfileText $desk
  if ($dout -match 'dsh-web-app') { throw "自检: 桌面端被写进了 dsh-web-app" }

  $wrong = '{"name":"dsh-profile-desktop","dependencies":{"@deepseek-ai/dsh-base":"2.0.0","dsh-purge":"9.9.9"},"dsh":{"profile":{"bundles":["dsh-purge","@deepseek-ai/dsh-base"],"patchReload":"live"}}}'
  $wout = Update-ProfileText $wrong
  if ($wout -match '"dsh-purge"\s*:\s*"9\.9\.9"') { throw "自检: 旧版本号还在" }
  if ($wout -notmatch '"dsh-purge": "file:../../plugins/dsh-purge"' -and $wout -notmatch '"dsh-purge":"file:../../plugins/dsh-purge"') {
    throw "自检: 没有改成 file: 相对路径"
  }
  if ($wout -notmatch '"bundles":\["dsh-purge","@deepseek-ai/dsh-base"\]') { throw "自检: 已有 bundle 被重排" }
  if ($wout -notmatch '"patchReload":"live"') { throw "自检: patchReload 变了" }
  if ($wout -notmatch '"@deepseek-ai/dsh-base":"2.0.0"') { throw "自检: 原依赖变了" }

  $emptyDep = '{"name":"dsh-profile-web","dependencies":{},"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base"],"patchReload":"live"}}}'
  $null = Update-ProfileText $emptyDep
  $emptyBun = '{"name":"dsh-profile-web","dependencies":{"a":"1"},"dsh":{"profile":{"bundles":[],"patchReload":"live"}}}'
  $null = Update-ProfileText $emptyBun

  $lf = "{`n  `"name`": `"dsh-profile-web`",`n  `"dependencies`": {`n    `"a`": `"1`"`n  },`n  `"dsh`": { `"profile`": { `"bundles`": [ `"only`" ], `"patchReload`": `"live`" } }`n}`n"
  if ($lf.Contains("`r")) { throw "自检: LF 样本构造错了" }
  $lout = Update-ProfileText $lf
  if ($lout.Contains("`r")) { throw "自检: LF 文件被改成了 CRLF" }

  $bad = '{"name":"dsh-profile-web","dependencies":{"a":"1"},"dsh":{"profile":{"patchReload":"live"}}}'
  $threw = $false
  try { Update-ProfileText $bad | Out-Null } catch {
    $threw = $true
    if ($_.Exception.Message -notmatch 'bundles') { throw }
  }
  if (-not $threw) { throw "自检: 缺少 bundles 时应该停止" }

  $tmpBase = $env:TEMP
  if (-not $tmpBase) { $tmpBase = $env:TMPDIR }
  if (-not $tmpBase) { $tmpBase = [System.IO.Path]::GetTempPath() }
  $tmp = Join-Path $tmpBase ("dsh-purge-jsontest-" + [guid]::NewGuid().ToString('N') + ".json")
  $sample = '{"description":"保持中文"}'
  Write-TextFile -Path $tmp -Text $sample -Info @{ Enc = 'utf8'; Bom = $false }
  try {
    $back = Read-TextFile $tmp
    if ($back.Text -ne $sample) { throw "自检: 编码往返失败" }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
  }
}

function Main {
  try { $Host.UI.RawUI.WindowTitle = 'dsh-purge install' } catch {}
  $selfTestOnly = $false
  $dryRun = $false
  $profileArg = ''
  $homeArg = ''
  foreach ($raw in @($script:RawArgs)) {
    if ($null -eq $raw) { continue }
    $a = "$raw".Trim()
    if (-not $a) { continue }
    if ($a -eq '-h' -or $a -eq '--help' -or $a -eq '/?' -or $a -eq '/help') {
      Show-Usage
      return
    }
    if ($a -eq '--self-test' -or $a -eq '-self-test') { $selfTestOnly = $true; continue }
    if ($a -eq '--dry-run' -or $a -eq '-dry-run') { $dryRun = $true; continue }
    $token = ''
    if ($a -notmatch '[\\/:]') {
      switch ($a.ToLower()) {
        'web' { $token = 'web' }
        'desktop' { $token = 'desktop' }
        'both' { $token = 'both' }
      }
    }
    if ($token) {
      if ($profileArg) { throw "profile 指定了两次: $profileArg 和 $token" }
      $profileArg = $token
      continue
    }
    if ($homeArg) { throw "无法识别参数: $a" }
    $homeArg = $a
  }

  Invoke-SelfTest
  Write-Host "JSON 补丁自检通过"
  if ($selfTestOnly) { return }
  if ($env:OS -ne 'Windows_NT') { throw "这个安装只支持 Windows" }

  Write-Host ""
  Write-Host "dsh-purge Windows 10 安装"
  Write-Host "仓库: $script:GitRepo"
  if ($dryRun) { Write-Host "当前是 dry-run，不会改文件，也不会执行 pnpm install" }
  Write-Host ""

  Sync-PathFromRegistry
  $picked = $null
  if ($homeArg) {
    $homeArg = $homeArg.Trim().Trim('"').TrimEnd('\')
    $note = Test-HomeLayout $homeArg
    if ($note) { throw "指定的 DSH_HOME 不能用: $homeArg （$note）" }
    $picked = @{ Path = $homeArg; Reason = '命令行指定' }
    $found = Get-HomeCandidates
  } else {
    $found = Get-HomeCandidates
    $valid = @($found.Valid)
    if ($valid.Count -eq 0) {
      Write-Host "没有找到可用的 DSH_HOME。检查过:"
      foreach ($c in @($found.Checked)) {
        $flag = '跳过'
        if ($c.Ok) { $flag = '可用' }
        Write-Host "  [$flag] $($c.Path)"
        Write-Host "         $($c.Reason) / $($c.Note)"
      }
      Write-Host "可以手动指定: install-win10.bat web `"D:\path\to\.dsh`""
      throw "没有找到可用的 DSH_HOME"
    }
    $envPick = $null
    foreach ($c in $valid) {
      if ($c.Reason -eq '环境变量 DSH_HOME') { $envPick = $c; break }
    }
    if ($envPick) {
      $picked = $envPick
    } elseif ($valid.Count -eq 1) {
      $picked = $valid[0]
    } else {
      Write-Host "找到多个 DSH_HOME。请选你实际启动的那一份:"
      $n = 1
      foreach ($c in $valid) {
        Write-Host "  [$n] $($c.Path)"
        Write-Host "      $($c.Reason)"
        $stats = @(Get-ProfileStatus $c.Path)
        foreach ($st in $stats) {
          $mark = '不可用'
          if ($st.Ok) { $mark = '可用' }
          Write-Host "      profile $($st.Name): $mark （$($st.Reason)）"
        }
        $n++
      }
      $choice = Read-Choice "      输入序号，q 退出" @(1..$valid.Count | ForEach-Object { "$_" })
      $picked = $valid[[int]$choice - 1]
    }
    if ($valid.Count -gt 1) {
      Write-Host "本次使用: $($picked.Path)"
      Write-Host "未使用的其它主目录:"
      foreach ($c in $valid) {
        if ($c.Path -eq $picked.Path) { continue }
        Write-Host "  $($c.Path) （$($c.Reason)）"
      }
      Write-Host "如果实际启动的不是这一份，请重跑并写上路径。"
    }
  }

  $dshHome = $picked.Path
  Write-Host "[1/4] DSH_HOME"
  Write-Host "      $dshHome"
  Write-Host "      来源: $($picked.Reason)"

  $stats = @(Get-ProfileStatus $dshHome)
  $okNames = New-Object System.Collections.Generic.List[string]
  foreach ($st in $stats) {
    if ($st.Ok) { [void]$okNames.Add([string]$st.Name) }
    else { Write-Host "      跳过 $($st.Name): $($st.Reason)" }
  }
  $selected = New-Object System.Collections.Generic.List[string]
  if ($profileArg -eq 'both') {
    foreach ($n in @($okNames)) { [void]$selected.Add([string]$n) }
    if ($selected.Count -eq 0) { throw "web 和 desktop 都不可用" }
  } elseif ($profileArg) {
    $hit = $null
    foreach ($st in $stats) { if ($st.Name -eq $profileArg) { $hit = $st } }
    if (-not $hit -or -not $hit.Ok) {
      $why = '不存在'
      if ($hit) { $why = $hit.Reason }
      throw "profile $profileArg 不可用: $why"
    }
    [void]$selected.Add([string]$profileArg)
  } elseif ($okNames.Count -eq 1) {
    [void]$selected.Add([string]$okNames[0])
  } elseif ($okNames.Count -eq 2) {
    Write-Host "这个主目录里 Web 和桌面端都在。手册要求只改正在用的那个宿主。"
    Write-Host "  [1] 只装 web"
    Write-Host "  [2] 只装 desktop"
    Write-Host "  [3] 两个都装"
    $which = Read-Choice "      输入 1 / 2 / 3，q 退出" @('1', '2', '3')
    if ($which -eq '1') { [void]$selected.Add('web') }
    elseif ($which -eq '2') { [void]$selected.Add('desktop') }
    else { [void]$selected.Add('web'); [void]$selected.Add('desktop') }
  } else {
    throw "没有可用的 web 或 desktop profile"
  }

  Write-Host "      将处理: $($selected -join ', ')"
  Write-Host ""
  Write-Host "[2/4] 插件目录"
  $dest = Join-Path $dshHome 'plugins\dsh-purge'
  Write-Host "      $dest"
  Sync-Plugin $dest $dryRun

  $done = New-Object System.Collections.Generic.List[string]
  foreach ($name in @($selected)) {
    $dir = Join-Path $dshHome ("profiles\" + $name)
    $pkg = Join-Path $dir 'package.json'
    Write-Host ""
    Write-Host "[3/4] 修改 $name"
    Write-Host "      $pkg"
    try {
      Update-ProfileFile $pkg $dryRun
      Write-Host ""
      Write-Host "[4/4] pnpm install ($name)"
      Write-Host "      目录 $dir"
      Invoke-PnpmInstall $dir $script:DshSource $dryRun
      if (-not $dryRun) {
        $marker = Join-Path $dir 'node_modules\dsh-purge\package.json'
        if (-not (Test-Path -LiteralPath $marker)) {
          throw "没有找到成功标志 $marker 。请检查 dependencies 里的 file:../../plugins/dsh-purge 。"
        }
        $mn = (Read-TextFile $marker).Text | ConvertFrom-Json
        if ($mn.name -ne 'dsh-purge') { throw "node_modules 里的 name 不是 dsh-purge" }
        Write-Host "      成功标志: $marker"
      }
      [void]$done.Add([string]$name)
    } catch {
      if ($done.Count -gt 0) { Write-Host "这些 profile 已经处理完: $($done -join ', ')" }
      throw
    }
  }

  if ($dryRun) {
    Write-Host ""
    Write-Host "dry-run 结束，没有修改文件。"
    return
  }
  Show-ManualSteps $dshHome $done
}

$script:RawArgs = @($args)
$script:DshSource = $null
try {
  Main
  exit 0
} catch {
  Write-Host ""
  Write-Host "安装失败:"
  Write-Host $_.Exception.Message
  if (@($script:Backups).Count -gt 0) {
    Write-Host "已留下的备份（这是修改前的 package.json）:"
    foreach ($b in @($script:Backups)) { Write-Host "  $b" }
    Write-Host "package.json 若已改好，修好 pnpm 后直接重跑即可，不必先还原。"
  }
  if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
  exit 1
}
