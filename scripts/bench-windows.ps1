# rtk Windows benchmark harness.
# Modes:
#   marker   - print max(id) of tracking DB (used as collection marker)
#   baseline - measure native commands (bypasses rtk rewrite via direct exe invocation)
#   collect  - read tracking DB rows after marker, aggregate per rtk_cmd, write collect.json
#   report   - join baseline.json + collect.json + matrix, write report.md
param(
  [Parameter(Mandatory = $true)][ValidateSet('marker', 'baseline', 'collect', 'report')] [string]$Mode,
  [string]$OutDir = "$env:TEMP\opencode\rtk-bench\results",
  [string]$DbPath = "$env:LOCALAPPDATA\rtk\history.db",
  [int]$Runs = 3,
  [int]$Marker = 0
)
$ErrorActionPreference = 'Stop'

$Git     = 'D:\git\Git\cmd\git.exe'
$GitUsr  = 'D:\git\Git\usr\bin'
$PyScr   = "$env:LOCALAPPDATA\Programs\Python\Python314\Scripts"
$RtkRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Scratch = "$env:TEMP\opencode\rtk-bench\git-repo"
$Js      = "$env:TEMP\opencode\rtk-bench\js-proj"
$PyProj  = "$env:TEMP\opencode\rtk-bench\py-proj"

# Matrix: tail = command the agent runs (pre-PATH-prefix); rtk = expected rtk_cmd suffix;
# exe/args/wd = native baseline invocation; useCmd = route through cmd.exe; pre = setup before each run.
$M = @(
  @{ id = 'git-status';       tail = 'git status';            rtk = 'rtk git status';            exe = $Git;              args = 'status';           wd = $RtkRoot },
  @{ id = 'git-log';          tail = 'git log --oneline -10'; rtk = 'rtk git log --oneline -10'; exe = $Git;              args = 'log --oneline -10'; wd = $RtkRoot },
  @{ id = 'git-diff';         tail = 'git diff';              rtk = 'rtk git diff';              exe = $Git;              args = 'diff';             wd = $RtkRoot },
  @{ id = 'git-diff-head5';   tail = 'git diff HEAD~5';       rtk = 'rtk git diff HEAD~5';       exe = $Git;              args = 'diff HEAD~5';      wd = $RtkRoot },
  @{ id = 'git-show';         tail = 'git show HEAD';         rtk = 'rtk git show HEAD';         exe = $Git;              args = 'show HEAD';        wd = $RtkRoot },
  @{ id = 'git-branch';       tail = 'git branch';            rtk = 'rtk git branch';            exe = $Git;              args = 'branch';           wd = $RtkRoot },
  @{ id = 'git-stash';        tail = 'git stash list';        rtk = 'rtk git stash list';        exe = $Git;              args = 'stash list';       wd = $RtkRoot },
  @{ id = 'git-worktree';     tail = 'git worktree list';     rtk = 'rtk git worktree';          exe = $Git;              args = 'worktree list';    wd = $RtkRoot },
  @{ id = 'git-add';          tail = 'git add .';             rtk = 'rtk git add .';             exe = $Git;              args = 'add .';            wd = $Scratch;
      pre = { Add-Content -Path (Join-Path $Scratch 'log.txt') -Value "bench $(Get-Random)" } },
  @{ id = 'git-commit';       tail = 'git commit -am bench';  rtk = 'rtk git commit';            exe = $Git;              args = 'commit -m bench';  wd = $Scratch;
      pre = { Add-Content -Path (Join-Path $Scratch 'log.txt') -Value "bench $(Get-Random)"; & $Git -C $Scratch add . 2>$null } },
  @{ id = 'git-checkout';     tail = 'git checkout';          rtk = 'rtk git checkout';          exe = $Git;              args = 'checkout';         wd = $Scratch },
  @{ id = 'npm-build';        tail = 'npm run build';         rtk = 'rtk npm run build';         exe = "$env:ProgramFiles\nodejs\npm.cmd";  args = 'run build';       wd = $Js; useCmd = $true },
  @{ id = 'npm-typecheck';    tail = 'npm run typecheck';     rtk = 'rtk npm run typecheck';     exe = "$env:ProgramFiles\nodejs\npm.cmd";  args = 'run typecheck';   wd = $Js; useCmd = $true },
  @{ id = 'npx-tsc';          tail = 'npx tsc --noEmit';      rtk = 'rtk tsc --noEmit';          exe = "$env:ProgramFiles\nodejs\npx.cmd";  args = 'tsc --noEmit';    wd = $Js; useCmd = $true },
  @{ id = 'npx-eslint';       tail = 'npx eslint .';          rtk = 'rtk lint eslint .';         exe = "$env:ProgramFiles\nodejs\npx.cmd";  args = 'eslint .';        wd = $Js; useCmd = $true },
  @{ id = 'npx-vitest';       tail = 'npx vitest run';        rtk = 'rtk npx vitest run';        exe = "$env:ProgramFiles\nodejs\npx.cmd";  args = 'vitest run';      wd = $Js; useCmd = $true },
  @{ id = 'npx-prettier';     tail = 'npx prettier --check .'; rtk = 'rtk prettier --check .';   exe = "$env:ProgramFiles\nodejs\npx.cmd";  args = 'prettier --check .'; wd = $Js; useCmd = $true },
  @{ id = 'pnpm-install';     tail = 'pnpm install';          rtk = 'rtk pnpm install';          exe = "$env:APPDATA\npm\pnpm.cmd";         args = 'install';         wd = $Js; useCmd = $true },
  @{ id = 'pnpm-list';        tail = 'pnpm list';             rtk = 'rtk pnpm list --depth=0';   exe = "$env:APPDATA\npm\pnpm.cmd";         args = 'list';            wd = $Js; useCmd = $true },
  @{ id = 'pnpm-outdated';    tail = 'pnpm outdated';         rtk = 'rtk pnpm outdated';         exe = "$env:APPDATA\npm\pnpm.cmd";         args = 'outdated';        wd = $Js; useCmd = $true },
  @{ id = 'pytest';           tail = 'pytest';                rtk = 'rtk pytest';                exe = "$PyScr\pytest.exe"; args = '';                 wd = $PyProj },
  @{ id = 'ruff-check';       tail = 'ruff check .';          rtk = 'rtk ruff check .';          exe = "$PyScr\ruff.exe";   args = 'check .';          wd = $PyProj },
  @{ id = 'ruff-format';      tail = 'ruff format --check .'; rtk = 'rtk ruff format --check .'; exe = "$PyScr\ruff.exe";   args = 'format --check .'; wd = $PyProj },
  @{ id = 'mypy';             tail = 'mypy .';                rtk = 'rtk mypy .';                exe = "$PyScr\mypy.exe";   args = '.';                wd = $PyProj },
  @{ id = 'pip-list';         tail = 'pip list';              rtk = 'rtk pip list';              exe = "$PyScr\pip.exe";    args = 'list';             wd = $PyProj },
  @{ id = 'ls';               tail = 'ls';                    rtk = 'rtk ls .';                  exe = "$GitUsr\ls.exe";    args = '';                 wd = $RtkRoot },
  @{ id = 'cat';              tail = 'cat Cargo.toml';        rtk = 'rtk read';                  exe = 'cmd.exe';           args = '/d /c type Cargo.toml'; wd = $RtkRoot; useCmd = $true },
  @{ id = 'tree';             tail = 'tree';                  rtk = 'rtk tree';                  exe = 'cmd.exe';           args = '/d /c tree /F';    wd = $RtkRoot; useCmd = $true },
  @{ id = 'grep-todo';        tail = 'grep -r TODO src';      rtk = 'rtk grep';                  exe = "$GitUsr\grep.exe";  args = '-r TODO src';      wd = $RtkRoot },
  @{ id = 'find-rs';          tail = 'find . -name *.rs';     rtk = 'rtk find';                  exe = "$GitUsr\find.exe";  args = '. -name *.rs';     wd = $RtkRoot },
  @{ id = 'wc';               tail = 'wc -l Cargo.toml';      rtk = 'rtk wc -l Cargo.toml';      exe = "$GitUsr\wc.exe";    args = '-l Cargo.toml';    wd = $RtkRoot },
  @{ id = 'diff-files';       tail = 'diff README.md app.txt'; rtk = 'rtk diff';                 exe = "$GitUsr\diff.exe";  args = 'README.md app.txt'; wd = $Scratch }
)

function Invoke-Measured {
  param($item)
  if ($item.pre) { $ErrorActionPreference = 'Continue'; & $item.pre; $ErrorActionPreference = 'Stop' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $item.wd
  if ($item.useCmd) {
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/d /s /c `"`"$($item.exe)`" $($item.args)`""
  } else {
    $psi.FileName = $item.exe
    $psi.Arguments = $item.args
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = [System.Diagnostics.Process]::Start($psi)
  $so = $p.StandardOutput.ReadToEndAsync()
  $se = $p.StandardError.ReadToEndAsync()
  $timeout = $false
  if (-not $p.WaitForExit(180000)) { $timeout = $true; try { $p.Kill() } catch {} }
  $sw.Stop()
  $out = ''; $err = ''
  try { $out = $so.Result } catch {}
  try { $err = $se.Result } catch {}
  $bytes = [Text.Encoding]::UTF8.GetByteCount($out) + [Text.Encoding]::UTF8.GetByteCount($err)
  [pscustomobject]@{ bytes = $bytes; ms = $sw.ElapsedMilliseconds; code = $p.ExitCode; timeout = $timeout }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

switch ($Mode) {
  'marker' {
    $row = & py -c "import sqlite3,sys; con=sqlite3.connect(r'$DbPath'); print(con.execute('SELECT COALESCE(MAX(id),0) FROM commands').fetchone()[0])"
    Write-Output $row
  }
  'baseline' {
    $all = @()
    foreach ($item in $M) {
      $runList = @()
      for ($i = 0; $i -lt $Runs; $i++) { $runList += Invoke-Measured $item }
      $all += [pscustomobject]@{
        id = $item.id; tail = $item.tail; wd = $item.wd
        bytes = @($runList | ForEach-Object { $_.bytes })
        ms    = @($runList | ForEach-Object { $_.ms })
        codes = @($runList | ForEach-Object { $_.code })
      }
      $b = ($runList | ForEach-Object { $_.bytes }) -join '/'
      $t = ($runList | ForEach-Object { $_.ms }) -join '/'
      Write-Output ("{0,-16} bytes={1,-20} ms={2}" -f $item.id, $b, $t)
    }
    $all | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutDir 'baseline.json') -Encoding utf8
    Write-Output "baseline.json written to $OutDir"
  }
  'collect' {
    $pyCode = @'
import sqlite3, json, sys
db, marker = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect(db)
rows = con.execute("SELECT original_cmd, rtk_cmd, input_tokens, output_tokens, exec_time_ms FROM commands WHERE id > ? ORDER BY id", (marker,)).fetchall()
agg = {}
for oc, rc, it, ot, ms in rows:
    rc = (rc or "").strip()
    a = agg.setdefault(rc, {"rtk_cmd": rc, "n": 0, "in": [], "out": [], "ms": [], "originals": []})
    a["n"] += 1; a["in"].append(it); a["out"].append(ot); a["ms"].append(ms or 0)
    if oc not in a["originals"]: a["originals"].append(oc)
for a in agg.values():
    n = len(a["in"])
    a["in_mean"] = sum(a["in"]) / n
    a["out_mean"] = sum(a["out"]) / n
    a["ms_mean"] = sum(a["ms"]) / n
print(json.dumps(list(agg.values())))
'@
    $tmpPy = Join-Path $env:TEMP 'rtk_collect.py'
    Set-Content -Path $tmpPy -Value $pyCode -Encoding UTF8
    $json = & py -X utf8 $tmpPy $DbPath $Marker
    $json | Out-File -FilePath (Join-Path $OutDir 'collect.json') -Encoding utf8
    Write-Output "collect.json written to $OutDir ($(($json | Measure-Object -Line).Lines) rtk_cmd groups)"
  }
  'report' {
    $baseline = Get-Content (Join-Path $OutDir 'baseline.json') -Raw | ConvertFrom-Json
    $collect  = Get-Content (Join-Path $OutDir 'collect.json') -Raw | ConvertFrom-Json
    if ($baseline -isnot [array]) { $baseline = @($baseline) }
    if ($collect  -isnot [array]) { $collect  = @($collect) }
    function Median([double[]]$v) {
      $s = $v | Sort-Object; $n = $s.Count
      if ($n -eq 0) { return 0.0 }
      if ($n % 2 -eq 1) { return $s[[int](($n - 1) / 2)] } else { return ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
    }
    $rows = @()
    $totRaw = 0.0; $totOut = 0.0; $totSavedMs = 0.0
    foreach ($item in $M) {
      $b = $baseline | Where-Object { $_.id -eq $item.id } | Select-Object -First 1
      $c = $collect | Where-Object { $_.rtk_cmd -eq $item.rtk -or $_.rtk_cmd -like "*; $($item.rtk)" } | Select-Object -First 1
      $rawBytes = 0.0; $nativeMs = 0.0
      if ($b) { $rawBytes = Median ([double[]]$b.bytes); $nativeMs = Median ([double[]]$b.ms) }
      $rewritten = 'NO'; $outBytes = 0.0; $rtkMs = 0.0; $rtkPct = 0.0; $n = 0
      if ($c) {
        $rewritten = 'YES'; $n = $c.n
        $outBytes = $c.out_mean * 4
        $rtkMs = $c.ms_mean
        $inTok = $c.in_mean
        if ($inTok -gt 0) { $rtkPct = [Math]::Round((($inTok - $c.out_mean) / $inTok) * 100, 1) }
      }
      $savedB = $rawBytes - $outBytes
      $pct = 0.0
      if ($rawBytes -gt 0) { $pct = [Math]::Round($savedB / $rawBytes * 100, 1) }
      $overhead = [Math]::Round($rtkMs - $nativeMs, 0)
      $verdict = '-'
      if ($rawBytes -gt 0) {
        if ($pct -ge 60) { $verdict = 'GOOD' } elseif ($pct -ge 30) { $verdict = 'WARN' } elseif ($pct -lt 0) { $verdict = 'NEG' } else { $verdict = 'LOW' }
        $totRaw += $rawBytes; $totOut += $outBytes
      }
      $rows += [pscustomobject]@{
        tail = $item.tail; rewritten = $rewritten; n = $n
        rawBytes = [int]$rawBytes; outBytes = [int]$outBytes; savedBytes = [int]$savedB
        pct = $pct; rtkPct = $rtkPct; nativeMs = [int]$nativeMs; rtkMs = [Math]::Round($rtkMs, 0); overhead = $overhead
        verdict = $verdict
      }
    }
    $lines = @()
    $lines += '# rtk Windows Benchmark Report'
    $lines += ''
    $lines += "- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $lines += "- Runs per command: $Runs (median used); bytes = stdout+stderr; tokens are rtk estimates (bytes/4, x4 restored)"
    $lines += "- rtk overhead = mean(rtk exec_time_ms) - median(native ms); note: rtk path is always warm-cache, native run 1 may be cold"
    $lines += ''
    $lines += '| Command | Rewritten | n | Raw B | Filtered B | Saved B | Saved % | rtk internal % | Native ms | rtk ms | Overhead ms | Verdict |'
    $lines += '|---|---|---|---|---|---|---|---|---|---|---|---|'
    foreach ($r in $rows) {
      $lines += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} |' -f $r.tail, $r.rewritten, $r.n, $r.rawBytes, $r.outBytes, $r.savedBytes, $r.pct, $r.rtkPct, $r.nativeMs, $r.rtkMs, $r.overhead, $r.verdict)
    }
    $totSaved = $totRaw - $totOut
    $totPct = 0.0; if ($totRaw -gt 0) { $totPct = [Math]::Round($totSaved / $totRaw * 100, 1) }
    $lines += ''
    $lines += "## Summary"
    $lines += ''
    $lines += "- Total raw bytes (measurable commands): $([int]$totRaw)"
    $lines += "- Total filtered bytes: $([int]$totOut)"
    $lines += "- Total saved bytes: $([int]$totSaved) ($totPct%)"
    $good = @($rows | Where-Object { $_.verdict -eq 'GOOD' }).Count
    $warn = @($rows | Where-Object { $_.verdict -eq 'WARN' }).Count
    $neg  = @($rows | Where-Object { $_.verdict -eq 'NEG' }).Count
    $norew = @($rows | Where-Object { $_.rewritten -eq 'NO' }).Count
    $lines += "- Verdicts: GOOD=$good WARN=$warn NEG=$neg, not-rewritten=$norew"
    $report = Join-Path $OutDir 'report.md'
    $lines | Out-File -FilePath $report -Encoding utf8
    Write-Output "report written: $report"
  }
}
