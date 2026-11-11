# Twitch EXE Moderator. Windows PowerShell 5.1. Requires Twitch account permission.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $root 'config.json'
$rulesPath = Join-Path $root 'rules.csv'
$tokenPath = Join-Path $root 'twitch_tokens.dpapi'
$config = Get-Content -Raw $configPath | ConvertFrom-Json
if ($config.client_id -match '^PASTE_' -or $config.channel -eq 'YOUR_CHANNEL_NAME') {
  Write-Host 'First, edit config.json: enter Twitch Client ID and channel name.' -ForegroundColor Yellow
  Write-Host 'Register a PUBLIC application at https://dev.twitch.tv/console/apps'
  exit 1
}
$channel = ([string]$config.channel).Trim().TrimStart('#').ToLowerInvariant()
if ($channel -notmatch '^[a-zA-Z0-9_]{3,25}$') { throw 'Invalid channel name in config.json' }
$clientId = [string]$config.client_id
$scopes = 'chat:read moderator:manage:chat_messages moderator:manage:banned_users'
function Save-Tokens($t) {
  $json = ($t | ConvertTo-Json -Compress -Depth 6)
  $secure = ConvertTo-SecureString -String $json -AsPlainText -Force
  ConvertFrom-SecureString -SecureString $secure | Set-Content -Path $tokenPath -Encoding ASCII
}
function Read-Tokens {
  if (-not (Test-Path $tokenPath)) { return $null }
  try {
    $secure = Get-Content -Raw $tokenPath | ConvertTo-SecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) | ConvertFrom-Json) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
  } catch { Write-Warning 'Stored login cannot be read; sign in again.'; return $null }
}
function Start-DeviceLogin {
  Write-Host 'Starting Twitch device authorization...' -ForegroundColor Cyan
  $dev = Invoke-RestMethod -Method Post -Uri 'https://id.twitch.tv/oauth2/device' -Body @{ client_id=$clientId; scopes=$scopes }
  Write-Host ('Visit: ' + $dev.verification_uri)
  Write-Host ('Enter code: ' + $dev.user_code) -ForegroundColor Yellow
  Start-Process $dev.verification_uri
  $deadline = (Get-Date).AddSeconds([double]$dev.expires_in)
  $interval = [Math]::Max(5, [int]$dev.interval)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $interval
    try {
      $t = Invoke-RestMethod -Method Post -Uri 'https://id.twitch.tv/oauth2/token' -Body @{ client_id=$clientId; scopes=$scopes; device_code=$dev.device_code; grant_type='urn:ietf:params:oauth:grant-type:device_code' }
      Save-Tokens $t
      return $t
    } catch {
      $msg = $_.ErrorDetails.Message
      if ($msg -match 'authorization_pending') { continue }
      if ($msg -match 'slow_down') { $interval += 5; continue }
      throw ('Twitch login failed: ' + $msg)
    }
  }
  throw 'Twitch sign-in expired. Run TwitchMod.exe again.'
}
function Refresh-Tokens($old) {
  if (-not $old -or -not $old.refresh_token) { return Start-DeviceLogin }
  try {
    $t = Invoke-RestMethod -Method Post -Uri 'https://id.twitch.tv/oauth2/token' -Body @{ client_id=$clientId; refresh_token=$old.refresh_token; grant_type='refresh_token' }
    Save-Tokens $t
    return $t
  } catch { Write-Warning 'Refresh expired. Please authorize again.'; return Start-DeviceLogin }
}
function Validate-Token($t) {
  try { return Invoke-RestMethod -Uri 'https://id.twitch.tv/oauth2/validate' -Headers @{ Authorization=('OAuth ' + $t.access_token) } }
  catch { return $null }
}
$script:tokens = Read-Tokens
if (-not $script:tokens) { $script:tokens = Start-DeviceLogin }
$identity = Validate-Token $script:tokens
if (-not $identity) { $script:tokens = Refresh-Tokens $script:tokens; $identity = Validate-Token $script:tokens }
if (-not $identity) { throw 'Could not validate Twitch authorization.' }
$requiredScopes = @('chat:read','moderator:manage:chat_messages','moderator:manage:banned_users')
foreach ($s in $requiredScopes) { if ($identity.scopes -notcontains $s) { throw "Missing permission $s. Delete twitch_tokens.dpapi and authorize again." } }
if ($identity.client_id -ne $clientId) { throw 'Token belongs to another client ID.' }
$moderatorId = [string]$identity.user_id
$moderatorName = [string]$identity.login
function Api($method, $url, $body=$null) {
  $headers = @{ 'Client-Id'=$clientId; 'Authorization'=('Bearer ' + $script:tokens.access_token) }
  $args = @{ Method=$method; Uri=('https://api.twitch.tv/helix/' + $url); Headers=$headers }
  if ($null -ne $body) { $args.ContentType='application/json'; $args.Body=($body | ConvertTo-Json -Depth 5 -Compress) }
  try { return Invoke-RestMethod @args }
  catch { throw ('Twitch API error: ' + $_.Exception.Message + ' ' + $_.ErrorDetails.Message) }
}
$broadcaster = Api 'Get' ('users?login=' + [uri]::EscapeDataString($channel))
if (-not $broadcaster.data -or $broadcaster.data.Count -eq 0) { throw "Channel not found: $channel" }
$broadcasterId = [string]$broadcaster.data[0].id
Write-Host ("Connected as @$moderatorName; watching #$channel") -ForegroundColor Green
Write-Host 'You must be channel owner or appointed moderator for moderation actions.'
$script:auto = [bool]$config.auto_moderation
$script:recent = New-Object System.Collections.ArrayList
$script:acted = @{}
$script:rules = @()
function Load-Rules {
  $script:rules = @(Import-Csv -Path $rulesPath | Where-Object { $_.Enabled -match '^(?i:true|yes|1)$' })
  foreach ($r in $script:rules) {
    if ($r.Action -notin @('delete','timeout','ban')) { throw ('Unknown action in rules.csv: ' + $r.Action) }
    if ($r.Match -notin @('contains','wholeword','exact')) { throw ('Unknown match in rules.csv: ' + $r.Match) }
    if ($r.Action -eq 'timeout' -and (([int]$r.Seconds) -lt 1 -or ([int]$r.Seconds) -gt 1209600)) { throw 'Timeout must be between 1 and 1209600 seconds.' }
    if ([string]::IsNullOrWhiteSpace($r.Pattern)) { throw 'Blank pattern in rules.csv.' }
  }
  Write-Host ('Loaded ' + $script:rules.Count + ' active dictionary rules; auto moderation: ' + $script:auto) -ForegroundColor Cyan
}
Load-Rules
function Matches-Rule($message,$rule) {
  $pattern = [regex]::Escape([string]$rule.Pattern)
  switch ($rule.Match) {
    'contains' { return [regex]::IsMatch($message, $pattern, 'IgnoreCase,CultureInvariant') }
    'wholeword' { return [regex]::IsMatch($message, '(?<![\p{L}\p{N}_])' + $pattern + '(?![\p{L}\p{N}_])', 'IgnoreCase,CultureInvariant') }
    'exact' { return [string]::Equals($message.Trim(), ([string]$rule.Pattern).Trim(), [StringComparison]::OrdinalIgnoreCase) }
  }
  return $false
}
function Moderate($action,$message,$seconds=600,$reason='Twitch EXE Moderator') {
  if ($message.login -eq $channel -or $message.login -eq $moderatorName) { Write-Warning 'Skipping broadcaster or self.'; return }
  if (-not $message.userId) { Write-Warning 'No user ID for this message'; return }
  if ($action -eq 'delete') {
    if (-not $message.id) { throw 'Message ID unavailable; refusing to clear whole chat.' }
    $query = ('moderation/chat?broadcaster_id=' + $broadcasterId + '&moderator_id=' + $moderatorId + '&message_id=' + [uri]::EscapeDataString($message.id))
    Api 'Delete' $query | Out-Null
  } else {
    $body = @{ data=@{ user_id=$message.userId; reason=$reason.Substring(0,[Math]::Min(500,$reason.Length)) } }
    if ($action -eq 'timeout') { $body.data.duration=[int]$seconds }
    $query = ('moderation/bans?broadcaster_id=' + $broadcasterId + '&moderator_id=' + $moderatorId)
    Api 'Post' $query $body | Out-Null
  }
  Write-Host ("[$action] @$($message.login): $($message.text)") -ForegroundColor Yellow
}
function Send-Irc($socket,[string]$line) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`r`n")
  $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
  $socket.SendAsync($seg,[Net.WebSockets.WebSocketMessageType]::Text,[bool]$true,[Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}
Write-Host 'Keys: A=auto on/off | R=reload dictionary | D=delete by number | T=timeout | B=ban | Q=quit'
$socket = New-Object Net.WebSockets.ClientWebSocket
$socket.ConnectAsync([uri]'wss://irc-ws.chat.twitch.tv:443',[Threading.CancellationToken]::None).GetAwaiter().GetResult()
Send-Irc $socket 'CAP REQ :twitch.tv/commands twitch.tv/tags'
Send-Irc $socket ('PASS oauth:' + $script:tokens.access_token)
Send-Irc $socket ('NICK ' + $moderatorName)
Send-Irc $socket ('JOIN #' + $channel)
$buffer = New-Object byte[] 8192
$segBuffer = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
$pending = $null
$assembled = ''
$running = $true
try {
while ($running -and $socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
  if (-not $pending) { $pending = $socket.ReceiveAsync($segBuffer,[Threading.CancellationToken]::None) }
  if ($pending.IsCompleted) {
    $result = $pending.GetAwaiter().GetResult()
    $pending = $null
    if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { break }
    $assembled += [Text.Encoding]::UTF8.GetString($buffer,0,$result.Count)
    if ($result.EndOfMessage) {
      $payload = $assembled; $assembled = ''
      foreach ($line in ($payload -split "`r?`n")) {
        if ($line -match '^PING :(.*)$') { Send-Irc $socket ('PONG :' + $Matches[1]); continue }
        if ($line -match ' NOTICE .*:(.*)$') { Write-Host ('NOTICE: ' + $Matches[1]); continue }
        if ($line -notmatch '^@([^ ]+) :([^! ]+)![^ ]+ PRIVMSG #[^ ]+ :(.*)$') { continue }
        $tagText = $Matches[1]; $senderLogin = $Matches[2]; $msgText = $Matches[3]
        $tags = @{}
        foreach ($pair in ($tagText -split ';')) { $parts=$pair -split '=',2; if ($parts.Count -eq 2) { $tags[$parts[0]]=$parts[1] } }
        $login = [string]$senderLogin
        $userId = [string]$tags['user-id']
        $msgId = [string]$tags['id']
        if (-not $login -or -not $userId) { continue }
        $isMod = ($tags['mod'] -eq '1' -or $tags['badges'] -match '(^|,)broadcaster/')
        $msg = [pscustomobject]@{ id=$msgId; login=$login; userId=$userId; text=$msgText; isMod=$isMod }
        [void]$script:recent.Add($msg)
        if ($script:recent.Count -gt 50) { $script:recent.RemoveAt(0) }
        Write-Host ("[$($script:recent.Count)] @$login : $msgText")
        if ([bool]$config.log_chat_locally) { Add-Content -Path (Join-Path $root 'chat.log') -Value ((Get-Date -Format o) + " @$login : $msgText") }
        if ($script:auto -and $login -ne $channel -and $login -ne $moderatorName -and (-not [bool]$config.skip_moderators -or -not $isMod)) {
          foreach ($rule in $script:rules) {
            if (Matches-Rule $msgText $rule) {
              try { Moderate $rule.Action $msg ([int]$rule.Seconds) ('Dictionary match: ' + $rule.Pattern) }
              catch { Write-Warning $_.Exception.Message }
              break
            }
          }
        }
      }
    }
  }
  if ([Console]::KeyAvailable) {
    $key = [Console]::ReadKey($true).KeyChar.ToString().ToUpperInvariant()
    switch ($key) {
      'A' { $script:auto = -not $script:auto; Write-Host ('Auto moderation: ' + $script:auto) -ForegroundColor Cyan }
      'R' { try { Load-Rules } catch { Write-Warning $_.Exception.Message } }
      'Q' { $running = $false }
      { $_ -in @('D','T','B') } {
        $choice = Read-Host 'Enter message number shown in brackets (recent list index)'
        $idx = 0
        if (-not [int]::TryParse($choice,[ref]$idx) -or $idx -lt 1 -or $idx -gt $script:recent.Count) { Write-Warning 'Invalid number'; break }
        $selected = $script:recent[$idx-1]
        $act = @{ D='delete'; T='timeout'; B='ban' }[$key]
        $duration = 600
        if ($key -eq 'T') {
          $s = Read-Host 'Timeout seconds (1-1209600; default 600)'
          if ($s -and ((-not [int]::TryParse($s,[ref]$duration)) -or $duration -lt 1 -or $duration -gt 1209600)) { Write-Warning 'Invalid duration'; break }
        }
        $confirm = Read-Host ("Confirm $act @$($selected.login) ? type YES")
        if ($confirm -ceq 'YES') { try { Moderate $act $selected $duration 'Manual moderation' } catch { Write-Warning $_.Exception.Message } }
      }
    }
  }
  Start-Sleep -Milliseconds 50
}
} finally {
  if ($socket -and $socket.State -eq [Net.WebSockets.WebSocketState]::Open) { try { $socket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure,'bye',[Threading.CancellationToken]::None).Wait(500) | Out-Null } catch {} }
  if ($socket) { $socket.Dispose() }
}
Write-Host 'Disconnected.'
