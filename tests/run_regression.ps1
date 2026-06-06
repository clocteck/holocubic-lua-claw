param(
  [string]$Base = "http://192.168.31.200",
  [switch]$RunAgent
)

$ErrorActionPreference = "Stop"
$Api = "$Base/esp_claw/api"
$Results = New-Object System.Collections.Generic.List[object]

function U8 {
  param([string]$Base64)
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

function Invoke-Claw {
  param(
    [hashtable]$Doc,
    [int]$TimeoutSec = 15
  )
  $json = $Doc | ConvertTo-Json -Compress -Depth 80
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  Invoke-RestMethod $Api -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec $TimeoutSec
}

function Add-Result {
  param(
    [string]$Name,
    [bool]$Passed,
    [string]$Detail = "",
    [string]$Kind = "test"
  )
  $script:Results.Add([pscustomobject]@{
    kind = $Kind
    name = $Name
    passed = $Passed
    detail = $Detail
  }) | Out-Null
  $mark = if ($Passed) { "PASS" } elseif ($Kind -eq "skip") { "SKIP" } else { "FAIL" }
  Write-Host ("[{0}] {1} {2}" -f $mark, $Name, $Detail)
}

function Issue-Codes {
  param($Doc)
  $codes = @()
  foreach ($e in @($Doc.errors)) {
    if ($e -and $e.code) { $codes += [string]$e.code }
  }
  foreach ($w in @($Doc.warnings)) {
    if ($w -and $w.code) { $codes += [string]$w.code }
  }
  $codes
}

function Test-Preflight {
  param(
    [string]$Name,
    [string]$Code,
    [bool]$ExpectOk,
    [string]$ExpectCode = ""
  )
  try {
    $doc = @{ action = "preflight_lua"; code = $Code }
    $r = Invoke-Claw -Doc $doc
    $codes = @(Issue-Codes $r)
    $ok = ($r.ok -eq $ExpectOk)
    if ($ExpectCode -ne "") {
      $ok = $ok -and ($codes -contains $ExpectCode)
    }
    Add-Result $Name $ok ("ok={0} codes={1}" -f $r.ok, ($codes -join ","))
  } catch {
    Add-Result $Name $false $_.Exception.Message
  }
}

function Test-Classify {
  param(
    [string]$Name,
    [string]$Message,
    [string]$Mode,
    [bool]$NeedsHistory,
    [string]$Target
  )
  try {
    $doc = @{ action = "classify_task"; message = $Message }
    $r = Invoke-Claw -Doc $doc
    $p = $r.plan
    $ok = $r.ok -and $p.mode -eq $Mode -and $p.needs_history -eq $NeedsHistory -and $p.target -eq $Target
    Add-Result $Name $ok ("mode={0} needs_history={1} target={2}" -f $p.mode, $p.needs_history, $p.target)
  } catch {
    Add-Result $Name $false $_.Exception.Message
  }
}

function Test-ClassifyTextFirst {
  param(
    [string]$Name,
    [string]$Message
  )
  try {
    $doc = @{ action = "classify_task"; message = $Message }
    $r = Invoke-Claw -Doc $doc
    $p = $r.plan
    $ok = $r.ok -and $p.execution_required -eq $false -and $p.allow_text_only -eq $true -and $p.text_first_request -eq $true
    Add-Result $Name $ok ("mode={0} execution_required={1} allow_text_only={2} text_first={3}" -f $p.mode, $p.execution_required, $p.allow_text_only, $p.text_first_request)
  } catch {
    Add-Result $Name $false $_.Exception.Message
  }
}

function Test-ClassifySemantic {
  param(
    [string]$Name,
    [string]$Message,
    [string]$Mode,
    [bool]$NeedsHistory,
    [string]$Target
  )
  try {
    $doc = @{ action = "classify_task"; message = $Message; semantic = $true }
    $r = Invoke-Claw -Doc $doc -TimeoutSec 45
    $p = $r.plan
    $ok = $r.ok -and $p.mode -eq $Mode -and $p.needs_history -eq $NeedsHistory -and $p.target -eq $Target
    Add-Result $Name $ok ("mode={0} needs_history={1} target={2} source={3}" -f $p.mode, $p.needs_history, $p.target, $p.router_source)
  } catch {
    Add-Result $Name $false $_.Exception.Message
  }
}

function Latest-Turn {
  param([string]$GoalPrefix)
  $doc = @{ action = "execution_ledger"; limit = 120 }
  $ledger = Invoke-Claw -Doc $doc
  $turn = $null
  foreach ($e in @($ledger.entries)) {
    if ($e.event -eq "turn_start" -and ([string]$e.user_goal).StartsWith($GoalPrefix)) {
      $turn = $e
    }
  }
  if (-not $turn) { return $null }
  $events = @($ledger.entries | Where-Object { $_.turn_id -eq $turn.turn_id })
  [pscustomobject]@{ start = $turn; events = $events }
}

function Turn-Tools {
  param($Turn)
  $tools = @()
  if (-not $Turn) { return $tools }
  foreach ($e in @($Turn.events)) {
    if ($e.tool) { $tools += [string]$e.tool }
    if ($e.tools) {
      foreach ($t in @($e.tools)) { $tools += [string]$t }
    }
  }
  $tools
}

function Turn-LuaOutputs {
  param($Turn)
  $outs = @()
  if (-not $Turn) { return $outs }
  foreach ($e in @($Turn.events)) {
    if ($e.event -eq "tool_result" -and $e.tool -eq "lua_run" -and $e.output) {
      $outs += $e.output
    }
  }
  $outs
}

function Turn-LuaStdoutText {
  param($Turn)
  $parts = @()
  foreach ($o in @(Turn-LuaOutputs $Turn)) {
    if ($o.stdout) { $parts += [string]$o.stdout }
    if ($o.result) { $parts += [string]$o.result }
    if ($o.error) { $parts += [string]$o.error }
  }
  ($parts -join "`n")
}

function Wait-ClawReady {
  param(
    [int]$TimeoutSec = 45
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $doc = @{ action = "state" }
      $state = Invoke-Claw -Doc $doc -TimeoutSec 8
      if ($state.ok -eq $true -and $state.busy -ne $true) {
        return $true
      }
    } catch {
    }
    Start-Sleep -Seconds 3
  }
  return $false
}

function Invoke-ChatJob {
  param(
    [string]$Message,
    [int]$TimeoutSec = 90
  )
  $doc = @{ action = "chat"; message = $Message }
  $r = Invoke-Claw -Doc $doc -TimeoutSec 12
  if ($r.job_id) {
    if ($r.busy -eq $true) {
      throw "chat busy: $($r.job.status)"
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 1
      try {
        $poll = Invoke-Claw -Doc @{ action = "chat_result"; job_id = $r.job_id } -TimeoutSec 8
        if ($poll.state) { $r.state = $poll.state }
        if ($poll.job.status -eq "done") {
          $r.reply = $poll.job.reply
          $r.ok = $true
          return $r
        }
        if ($poll.job.status -eq "error") {
          $r.reply = $poll.job.error
          $r.ok = $false
          return $r
        }
      } catch {
      }
    }
    throw "chat job timeout: $($r.job_id)"
  }
  return $r
}

Write-Host "ESP Claw regression tests: $Api"

try {
  $doc = @{ action = "state" }
  $state = Invoke-Claw -Doc $doc
  Add-Result "service state" ($state.ok -eq $true -and $state.llm_ready -eq $true) ("route={0}" -f $state.route_base)
} catch {
  Add-Result "service state" $false $_.Exception.Message
}

try {
  $doc = @{ action = "self_check" }
  $self = Invoke-Claw -Doc $doc -TimeoutSec 25
  Add-Result "self_check all ok" ($self.ok -eq $true -and $self.summary.fail -eq 0) ("ok={0} warn={1} fail={2}" -f $self.summary.ok, $self.summary.warn, $self.summary.fail)
} catch {
  Add-Result "self_check all ok" $false $_.Exception.Message
}

try {
  $doc = @{ action = "code_capabilities" }
  $cap = Invoke-Claw -Doc $doc
  $lineSig = [string]$cap.capabilities.canvas.draw_line
  Add-Result "capabilities canvas signature" ($lineSig -eq "lv_canvas_draw_line(cvs,x1,y1,x2,y2,color,opa)") $lineSig
  Add-Result "capabilities no lv_color_hex" (-not ([string]$cap.capabilities.lvgl.colors).Contains("lv_color_hex is available")) ([string]$cap.capabilities.lvgl.colors)
} catch {
  Add-Result "code capabilities" $false $_.Exception.Message
}

Test-Classify "classify new triple pendulum" (U8 "5biu5oiR55S75LiA5LiqM+S4quaRhueahOa3t+ayjOi/kOWKqO+8jOimgeiAg+iZkeecn+WunueahOmHjeWKmw==") "new_code" $false "panel"
Test-Classify "classify modify current artifact" (U8 "5Zyo5b2T5YmN5Y2V5pGG6JOd6Imy6L2o6L+55Z+656GA5LiK77yM5oqK5pGG6ZSk5pS55oiQ57u/6Imy77yM6L2o6L+55L+d55WZ6JOd6Imy") "modify_previous" $true "panel"
Test-Classify "classify debug previous visual" (U8 "5pGG5p2G57q/5p2h5rKh55S75Ye65p2l") "debug_previous" $true "panel"
Test-Classify "classify service lua run" (U8 "6L+Q6KGM5LiA5q61IEx1YSDmiZPljbAgaGVsbG/vvIzlj6rpnIDopoHmiafooYw=") "new_code" $false "service"
Test-ClassifyTextFirst "classify text-first code mention" (U8 "5L2g6IO96K6/6Zeu5LqS6IGU572R5ZCXP+iDvee7meiHquW3seWinuWKoOiuv+mXruS6kuiBlOe9keeahHNraWxs5ZCXPyjpgJrov4fnm7TmjqXkv67mlLnoh6rlt7HnmoTku6PnoIEpIOWFiOaWh+Wtl+WbnuWkjQ==")
Test-Classify "classify live price weak fallback" (U8 "5p+l6K+i5LuK5aSp6buE6YeR55m96ZO25Lu35qC8") "answer" $false "unknown"
Test-ClassifySemantic "classify semantic live price lookup" (U8 "5p+l6K+i5LuK5aSp6buE6YeR55m96ZO25Lu35qC8") "live_lookup" $false "service"

Test-Preflight "preflight lv_color_hex" 'local root=lv_scr_act(); local c=lv_color_hex(0xff0000)' $false "unknown_color_api"
Test-Preflight "preflight timer register" 'local t=tmr.create(); t:register(50, tmr.REPEAT, function() end)' $false "timer_register_pattern"
Test-Preflight "preflight draw_line arg order" 'local root=lv_scr_act(); local cvs=lv_canvas_create(root,320,240); lv_canvas_frame_begin(cvs); lv_canvas_draw_line(cvs,0,0,10,10,2,0xFF0000); lv_canvas_frame_end(cvs)' $false "draw_line_arg_order"
Test-Preflight "preflight float pixel literal" 'local root=lv_scr_act(); local o=lv_obj_create(root); lv_obj_set_pos(o, 1.5, 2)' $false "float_pixel_literal"
Test-Preflight "preflight os module unavailable" 'local os=require("os"); print(os.time())' $false "module_unavailable"
Test-Preflight "preflight require json unavailable" 'local json=require("json"); print(json.encode({ok=true}))' $false "module_unavailable"
Test-Preflight "preflight lv_align constant unavailable" 'local root=lv_scr_act(); local label=lv_label_create(root); lv_obj_align(label, lv_align_center, 0, 0)' $false "unknown_lvgl_constant"
Test-Preflight "preflight canvas missing frame warning" 'local root=lv_scr_act(); local cvs=lv_canvas_create(root,320,240); lv_canvas_draw_line(cvs,0,0,10,10,0xFF0000,255)' $true "canvas_frame_begin_missing"

$goodBall = @'
local root = lv_scr_act()
lv_obj_clean(root)
local ball = lv_obj_create(root)
lv_obj_set_size(ball, 30, 30)
lv_obj_set_style_bg_color(ball, 0xFF3333, 0)
lv_obj_set_style_radius(ball, 15, 0)
lv_obj_set_pos(ball, 10, 100)
local timer = add_timer(tmr.create())
timer:alarm(40, tmr.ALARM_AUTO, function()
  lv_obj_set_x(ball, 20)
end)
'@
Test-Preflight "preflight valid red ball object" $goodBall $true

try {
  $doc = @{ action = "panel_artifacts"; include_code = $false; query = (U8 "5Y2V5pGGIOiTneiJsui9qOi/uSBwZW5kdWx1bQ=="); limit = 5 }
  $art = Invoke-Claw -Doc $doc
  $found = @($art.entries).Count -gt 0
  $kind = if ($found) { "test" } else { "skip" }
  Add-Result "artifact tokenized query" $found ("count={0}" -f @($art.entries).Count) $kind
} catch {
  Add-Result "artifact tokenized query" $false $_.Exception.Message
}

if (Test-Path "web.html") {
  $html = Get-Content -Path "web.html" -Raw -Encoding UTF8
  $white = $html.Contains("#f8fafc") -or $html.Contains("#ffffff") -or $html.Contains("background: #fff")
  Add-Result "web light theme marker" $white
}

if ($RunAgent) {
  Write-Host ""
  Write-Host "Running live LLM/Panel agent tests..."
  Write-Host "Complex live prompts:"
  Write-Host "1. Review Lua nil-field bug, text only, no execution."
  Write-Host "2. Run service Lua to sort data and print COMPLEX_STATS."
  Write-Host "3. Draw and run an 8-dot rotating Panel animation."
  Write-Host "4. Follow up: debug/continue the previous visual while preserving rotation."
  Write-Host "5. Inspect /sd/apps/esp_claw entry and Skill-Tool prompt injection."

  try {
    [void](Invoke-Claw -Doc @{ action = "reset" } -TimeoutSec 12)
  } catch {
    Add-Result "agent complex reset" $false $_.Exception.Message
  }

  try {
    $msg = U8 "5Zue5b2S5rWL6K+V77ya6L+Q6KGM5LiA5q61IEx1YSDmiZPljbAgaGVsbG/vvIzlj6rpnIDopoHmiafooYw="
    $r = Invoke-ChatJob $msg 90
    $ok = $r.ok -eq $true -and ([string]$r.reply).Contains("hello")
    Add-Result "agent service hello" $ok ([string]$r.reply)
  } catch {
    Add-Result "agent service hello" $false $_.Exception.Message
    [void](Wait-ClawReady 45)
  }

  try {
    $msg = U8 "5L2g556F556F6L+Z5q61IEx1YSDmnInmsqHmnInmr5vnl4XvvIzlj6ror7Tpl67popjvvIzkuI3opoHov5DooYzvvJoKYGBgbHVhCmxvY2FsIHVzZXIgPSBuaWwKcHJpbnQodXNlci5uYW1lKQpgYGA="
    $prefix = U8 "5L2g556F556F6L+Z5q61IEx1YSDmnInmsqHmnInmr5vnl4U="
    $r = Invoke-ChatJob $msg 90
    $turn = Latest-Turn $prefix
    $tools = @(Turn-Tools $turn)
    $reply = [string]$r.reply
    $ok = $r.ok -eq $true -and -not ($tools -contains "lua_run") -and ($reply.Contains("nil") -or $reply.Contains("user.name"))
    Add-Result "agent complex review no run" $ok ("tools={0} reply={1}" -f ($tools -join ","), $reply.Substring(0, [Math]::Min(180, $reply.Length)))
  } catch {
    Add-Result "agent complex review no run" $false $_.Exception.Message
    [void](Wait-ClawReady 45)
  }

  try {
    $msg = U8 "5biu5oiR6L+Q6KGM5LiA5q61IEx1Ye+8muaehOmAoOaVsOe7hCB7NywyLDksNCw2LDF977yM5o6S5bqP5ZCO57uf6K6h5YG25pWw5Liq5pWw5ZKM5oC75ZKM77yM5pyA5ZCO5b+F6aG7IHByaW50IOS4gOihjOS7pSBDT01QTEVYX1NUQVRTIOW8gOWktOeahCBKU09OIOaRmOimgeOAgg=="
    $prefix = U8 "5biu5oiR6L+Q6KGM5LiA5q61IEx1Ye+8muaehOmAoOaVsOe7hA=="
    $r = Invoke-ChatJob $msg 110
    $turn = Latest-Turn $prefix
    $tools = @(Turn-Tools $turn)
    $stdout = Turn-LuaStdoutText $turn
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and $stdout.Contains("COMPLEX_STATS") -and $stdout.Contains("29") -and $stdout.Contains("3")
    Add-Result "agent complex service stats" $ok ("tools={0} stdout={1}" -f ($tools -join ","), $stdout)
  } catch {
    Add-Result "agent complex service stats" $false $_.Exception.Message
    [void](Wait-ClawReady 60)
  }

  try {
    $msg = U8 "5biu5oiR5Zyo5bGP5bmV5LiK55S75LiA5LiqIDgg5Liq54K5546v57uV5Lit5b+D5peL6L2s55qE5Yqo55S777yM6L+Q6KGM6LW35p2l44CC6K+355SoIFBhbmVsL0xWR0zvvIzmiZPljbAgQ09NUExFWF9QQU5FTF9PS+OAgg=="
    $prefix = U8 "5biu5oiR5Zyo5bGP5bmV5LiK55S75LiA5LiqIDgg5Liq54K5"
    $r = Invoke-ChatJob $msg 120
    $turn = Latest-Turn $prefix
    $tools = @(Turn-Tools $turn)
    $outs = @(Turn-LuaOutputs $turn)
    $stdout = Turn-LuaStdoutText $turn
    $targets = @($outs | ForEach-Object { [string]$_.target })
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and ($targets -contains "panel") -and ($stdout.Contains("COMPLEX_PANEL_OK") -or $r.state.code_runner.last_ok -eq $true)
    Add-Result "agent complex panel orbit" $ok ("tools={0} targets={1} stdout={2}" -f ($tools -join ","), ($targets -join ","), $stdout)
  } catch {
    Add-Result "agent complex panel orbit" $false $_.Exception.Message
    [void](Wait-ClawReady 70)
  }

  try {
    $msg = U8 "5Li65LuA5LmI5Yia5omN55S75LiN5Ye65p2l77yf5L2g5L+u5LiA5LiL5bm257un57ut6L+Q6KGM77yM5L+d55WZIDgg5Liq54K55peL6L2s5pWI5p6c77yM5omT5Y2wIENPTVBMRVhfUEFORUxfRklY44CC"
    $prefix = U8 "5Li65LuA5LmI5Yia5omN55S75LiN5Ye65p2l"
    $r = Invoke-ChatJob $msg 120
    $turn = Latest-Turn $prefix
    $tools = @(Turn-Tools $turn)
    $outs = @(Turn-LuaOutputs $turn)
    $stdout = Turn-LuaStdoutText $turn
    $targets = @($outs | ForEach-Object { [string]$_.target })
    $usedHistory = ($tools -contains "get_panel_artifacts") -or ($tools -contains "get_panel_history")
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and ($targets -contains "panel") -and $usedHistory -and ($stdout.Contains("COMPLEX_PANEL_FIX") -or $r.state.code_runner.last_ok -eq $true)
    Add-Result "agent complex panel followup" $ok ("tools={0} targets={1} stdout={2}" -f ($tools -join ","), ($targets -join ","), $stdout)
  } catch {
    Add-Result "agent complex panel followup" $false $_.Exception.Message
    [void](Wait-ClawReady 70)
  }

  try {
    $msg = U8 "55yL5LiLIC9zZC9hcHBzL2VzcF9jbGF3IOeahOWFpeWPo+WSjCBTa2lsbC1Ub29sIOaYoOWwhOaYr+aAjuS5iOazqOWFpSBwcm9tcHQg55qE77yM566A55+t5oC757uT44CC"
    $prefix = U8 "55yL5LiLIC9zZC9hcHBzL2VzcF9jbGF3IOeahOWFpeWPow=="
    $r = Invoke-ChatJob $msg 120
    $turn = Latest-Turn $prefix
    $tools = @(Turn-Tools $turn)
    $reply = [string]$r.reply
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and $reply.Contains("main.lua") -and ($reply.Contains("Skill-Tool") -or $reply.Contains("skill_tool_context") -or $reply.Contains("build_context"))
    Add-Result "agent complex inspect skill map" $ok ("tools={0} reply={1}" -f ($tools -join ","), $reply.Substring(0, [Math]::Min(220, $reply.Length)))
  } catch {
    Add-Result "agent complex inspect skill map" $false $_.Exception.Message
    [void](Wait-ClawReady 70)
  }

<#

  try {
    $msg = @'
你瞅瞅这段 Lua 有没有毛病，只说问题，不要运行：
```lua
local user = nil
print(user.name)
```
'@
    $r = Invoke-ChatJob $msg 90
    $turn = Latest-Turn "你瞅瞅这段 Lua 有没有毛病"
    $tools = @(Turn-Tools $turn)
    $reply = [string]$r.reply
    $ok = $r.ok -eq $true -and -not ($tools -contains "lua_run") -and ($reply.Contains("nil") -or $reply.Contains("空"))
    Add-Result "agent complex review no run" $ok ("tools={0} reply={1}" -f ($tools -join ","), $reply.Substring(0, [Math]::Min(180, $reply.Length)))
  } catch {
    Add-Result "agent complex review no run" $false $_.Exception.Message
    [void](Wait-ClawReady 45)
  }

  try {
    $msg = @'
帮我运行一段 Lua：构造数组 {7,2,9,4,6,1}，排序后统计偶数个数和总和，最后必须 print 一行以 COMPLEX_STATS 开头的 JSON 摘要。
'@
    $r = Invoke-ChatJob $msg 110
    $turn = Latest-Turn "帮我运行一段 Lua：构造数组"
    $tools = @(Turn-Tools $turn)
    $stdout = Turn-LuaStdoutText $turn
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and $stdout.Contains("COMPLEX_STATS") -and $stdout.Contains("29") -and $stdout.Contains("3")
    Add-Result "agent complex service stats" $ok ("tools={0} stdout={1}" -f ($tools -join ","), $stdout)
  } catch {
    Add-Result "agent complex service stats" $false $_.Exception.Message
    [void](Wait-ClawReady 60)
  }

  try {
    $msg = @'
帮我在屏幕上画一个 8 个点环绕中心旋转的动画，运行起来。请用 Panel/LVGL，打印 COMPLEX_PANEL_OK。
'@
    $r = Invoke-ChatJob $msg 120
    $turn = Latest-Turn "帮我在屏幕上画一个 8 个点"
    $tools = @(Turn-Tools $turn)
    $outs = @(Turn-LuaOutputs $turn)
    $stdout = Turn-LuaStdoutText $turn
    $targets = @($outs | ForEach-Object { [string]$_.target })
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and ($targets -contains "panel") -and ($stdout.Contains("COMPLEX_PANEL_OK") -or $r.state.code_runner.last_ok -eq $true)
    Add-Result "agent complex panel orbit" $ok ("tools={0} targets={1} stdout={2}" -f ($tools -join ","), ($targets -join ","), $stdout)
  } catch {
    Add-Result "agent complex panel orbit" $false $_.Exception.Message
    [void](Wait-ClawReady 70)
  }

  try {
    $msg = "为什么刚才画不出来？你修一下并继续运行，保留 8 个点旋转效果，打印 COMPLEX_PANEL_FIX。"
    $r = Invoke-ChatJob $msg 120
    $turn = Latest-Turn "为什么刚才画不出来"
    $tools = @(Turn-Tools $turn)
    $outs = @(Turn-LuaOutputs $turn)
    $stdout = Turn-LuaStdoutText $turn
    $targets = @($outs | ForEach-Object { [string]$_.target })
    $usedHistory = ($tools -contains "get_panel_artifacts") -or ($tools -contains "get_panel_history")
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and ($targets -contains "panel") -and $usedHistory -and ($stdout.Contains("COMPLEX_PANEL_FIX") -or $r.state.code_runner.last_ok -eq $true)
    Add-Result "agent complex panel followup" $ok ("tools={0} targets={1} stdout={2}" -f ($tools -join ","), ($targets -join ","), $stdout)
  } catch {
    Add-Result "agent complex panel followup" $false $_.Exception.Message
    [void](Wait-ClawReady 70)
  }

  try {
    $msg = "看下 /sd/apps/esp_claw 的入口和 Skill-Tool 映射是怎么注入 prompt 的，简短总结。"
    $r = Invoke-ChatJob $msg 120
    $turn = Latest-Turn "看下 /sd/apps/esp_claw 的入口"
    $tools = @(Turn-Tools $turn)
    $reply = [string]$r.reply
    $ok = $r.ok -eq $true -and ($tools -contains "lua_run") -and $reply.Contains("main.lua") -and ($reply.Contains("Skill-Tool") -or $reply.Contains("skill_tool_context") -or $reply.Contains("build_context"))
    Add-Result "agent complex inspect skill map" $ok ("tools={0} reply={1}" -f ($tools -join ","), $reply.Substring(0, [Math]::Min(220, $reply.Length)))
  } catch {
    Add-Result "agent complex inspect skill map" $false $_.Exception.Message
    [void](Wait-ClawReady 70)
  }

  #>

  try {
    $msg = U8 "5Zue5b2S5rWL6K+V77ya5biu5oiR55S75LiA5Liq5q2j5Zyo5bem5Y+z56e75Yqo55qE57qi6Imy5bCP55CD"
    $r = Invoke-ChatJob $msg 100
    $turn = Latest-Turn $msg
    $tools = @(Turn-Tools $turn)
    $ok = $r.ok -eq $true -and $r.state.code_runner.last_ok -eq $true -and -not ($tools -contains "get_panel_artifacts")
    Add-Result "agent new code ignores artifacts" $ok ("tools={0}" -f ($tools -join ","))
  } catch {
    Add-Result "agent new code ignores artifacts" $false $_.Exception.Message
    [void](Wait-ClawReady 60)
  }

  try {
    $doc = @{ action = "panel_artifacts"; include_code = $false; query = "pendulum_blue_trail"; limit = 1 }
    $art = Invoke-Claw -Doc $doc
    if (@($art.entries).Count -eq 0) {
      Add-Result "agent modify keeps matching artifact" $false "pendulum_blue_trail missing" "skip"
    } else {
      $msg = U8 "5Zyo5b2T5YmN5Y2V5pGG6JOd6Imy6L2o6L+55Z+656GA5LiK77yM5oqK5pGG6ZSk5pS55oiQ57u/6Imy77yM6L2o6L+55L+d55WZ6JOd6Imy77yM5Yir6YeN5YaZ5oiQ5Yir55qEIGRlbW8="
      $r = Invoke-ChatJob $msg 100
      $doc = @{ action = "panel_artifacts"; include_code = $true; query = "pendulum_blue_trail"; limit = 1 }
      $updated = Invoke-Claw -Doc $doc
      $updatedEntry = @($updated.entries)[0]
      $code = [string]$updatedEntry.code
      $ok = $r.ok -eq $true -and $r.state.code_runner.last_ok -eq $true -and $code.Contains("0x00CC66") -and $code.Contains("0x4DA3FF")
      Add-Result "agent modify keeps matching artifact" $ok ("checksum={0}" -f $updatedEntry.code_checksum)
    }
  } catch {
    Add-Result "agent modify keeps matching artifact" $false $_.Exception.Message
    [void](Wait-ClawReady 60)
  }
}

$failed = @($Results | Where-Object { $_.passed -eq $false -and $_.kind -ne "skip" })
$skipped = @($Results | Where-Object { $_.kind -eq "skip" })
$passed = $Results.Count - $failed.Count - $skipped.Count
Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $passed, $failed.Count, $skipped.Count)
if ($failed.Count -gt 0) {
  Write-Host "Failures:"
  foreach ($f in $failed) {
    Write-Host ("- {0}: {1}" -f $f.name, $f.detail)
  }
  exit 1
}
