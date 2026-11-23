# Compiles the real expressions of the open product policy (Product_EntraOpen_Policy.xml), the
# usageId / usageName variables of the inference policies and the usage trace fragment against a
# fake APIM context, and checks them with hand-made (unsigned) tokens: which tokens are treated
# as service principals, which object id, name and client the caller gets, and how a keyed or a
# keyless request is named. It also checks the policy files statically: that no inference policy
# reads context.Subscription outside the two usageId / usageName variables, and that no policy
# uses a Regex member APIM does not allow, and that every API spec in api_definitions declares the
# gateway's credentials (the x-api-key header or an Entra bearer token) and nothing else.
# It needs PowerShell 7 (pwsh), which has the C# compiler and Newtonsoft.Json. It does not run
# APIM, so APIM's own limits on allowed types, and validate-azure-ad-token itself, are not
# checked here: the tokens are not signed and are never validated.
#
#   pwsh -NoProfile -File tests/policy/caller-policy-test.ps1
#
# Exit status 1 when a check fails.
param(
    [string]$PolicyDir = (Join-Path $PSScriptRoot '../../apim_policies')
)
$WarningPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$bad = 0
function Check($ok, $what) {
    if (-not $ok) { $script:bad++ }
    '{0,-6} {1}' -f $(if ($ok) { 'OK' } else { 'WRONG' }), $what
}

# ---- static checks -------------------------------------------------------------------------
$allowedRegex = @('IsMatch', 'Match', 'Matches', 'Replace', 'Unescape', 'Split')
foreach ($file in Get-ChildItem -Path $PolicyDir -Filter '*.xml') {
    $text = Get-Content -Raw $file.FullName
    foreach ($m in [regex]::Matches($text, 'RegularExpressions\.Regex\.(\w+)')) {
        Check ($allowedRegex -contains $m.Groups[1].Value) ('{0}: Regex.{1} is an APIM-allowed member' -f $file.Name, $m.Groups[1].Value)
    }
}
$inference = @(
    'AOAI_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'OpenAIv1Messages_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'Anthropic_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'BlackForestLabs_Policy-Managed_Identity_with_Retry_MultiRegion.xml',
    'MAI_Image_Policy-Managed_Identity_with_Retry.xml'
)
foreach ($name in $inference + @('ClaudeAuto_Fragment.xml', 'RequestBodyLog_Fragment.xml', 'UsageTrace_Fragment.xml')) {
    $text = Get-Content -Raw (Join-Path $PolicyDir $name)
    # Only the usageId and usageName variables may read the subscription; without a key it is null.
    $reads = [regex]::Matches($text, 'context\.Subscription\.(Id|Name)').Count
    $allowed = if ($inference -contains $name) { 2 } else { 0 }
    Check ($reads -eq $allowed) ('{0}: reads context.Subscription.Id/Name {1} time(s), expected {2}' -f $name, $reads, $allowed)
}
foreach ($name in $inference) {
    $text = Get-Content -Raw (Join-Path $PolicyDir $name)
    $first = $text.IndexOf('name="usageId"')
    $use = $text.IndexOf('GetValueOrDefault(&quot;usageId&quot;')
    Check (($first -ge 0) -and ($use -gt $first)) ('{0}: usageId is set before it is read' -f $name)
    $base = $text.IndexOf('<base />')
    Check (($base -ge 0) -and ($first -gt $base)) ('{0}: usageId is set after the first <base /> (the product policy has run)' -f $name)
}
# Every image route limits requests per caller with one shared counter, set from usageId and
# placed before the request body log, so a refused request is neither sent nor stored.
$imageLimitKey = 'counter-key="@(&quot;images:&quot; + (string)context.Variables.GetValueOrDefault(&quot;usageId&quot;, &quot;&quot;))"'
foreach ($name in $inference) {
    $text = Get-Content -Raw (Join-Path $PolicyDir $name)
    $limits = [regex]::Matches($text, '<rate-limit-by-key [^>]*>')
    if ($name -like 'Anthropic*') {
        Check ($limits.Count -eq 0) ('{0}: no image request limit (no image routes)' -f $name)
        continue
    }
    # The AOAI policy (the deployment routes) also limits audio transcription requests, with their own counter.
    $audio = $name -like 'AOAI*'
    Check (($limits.Count -eq $(if ($audio) { 2 } else { 1 })) -and $limits[0].Value.Contains($imageLimitKey) -and $limits[0].Value.Contains('calls="__IMAGE_REQUESTS_PER_MINUTE__"')) ('{0}: image request limit, keyed images:usageId' -f $name)
    $at = $text.IndexOf('<rate-limit-by-key')
    Check (($at -gt $text.IndexOf('name="usageId"')) -and ($at -lt $text.IndexOf('<!-- __REQUEST_LOG__ -->'))) ('{0}: image limit is after usageId and before the request log' -f $name)
    if ($audio) {
        $audioKey = 'counter-key="@(&quot;audio:&quot; + (string)context.Variables.GetValueOrDefault(&quot;usageId&quot;, &quot;&quot;))"'
        Check ($limits[1].Value.Contains($audioKey) -and $limits[1].Value.Contains('calls="__AUDIO_REQUESTS_PER_MINUTE__"')) ('{0}: audio request limit, keyed audio:usageId' -f $name)
        $at = $text.LastIndexOf('<rate-limit-by-key')
        Check (($at -gt $text.IndexOf('name="usageId"')) -and ($at -lt $text.IndexOf('<!-- __REQUEST_LOG__ -->'))) ('{0}: audio limit is after usageId and before the request log' -f $name)
        Check ($text.Contains('name="isAudioRequest"') -and $text.Contains('name="Audio Count"')) ('{0}: skips the token limit for audio and counts audio requests' -f $name)
    }
}
# The request body log stores no audio: an audio upload is replaced by one text line.
$logText = Get-Content -Raw (Join-Path $PolicyDir 'RequestBodyLog_Fragment.xml')
Check ($logText.Contains('Path.Contains(&quot;/audio/&quot;)') -and $logText.Contains('audio upload not stored')) 'RequestBodyLog_Fragment.xml: audio uploads are not stored'

# Every API spec declares the gateway's credentials, not Azure's: the x-api-key header or an Entra
# token (bearer), at the top level, with no operation overriding them. A client generated from a
# spec otherwise sends the key under a name the gateway does not read.
$specDir = Join-Path $PolicyDir '../api_definitions'
foreach ($file in Get-ChildItem -Path $specDir -Filter '*.json') {
    $spec = Get-Content -Raw $file.FullName | ConvertFrom-Json -AsHashtable
    $schemes = $spec.components.securitySchemes
    $key = $schemes.apiKeyHeader
    $tok = $schemes.entraToken
    Check (($schemes.Keys.Count -eq 2) -and $key -and $tok) ('{0}: declares exactly apiKeyHeader and entraToken' -f $file.Name)
    Check ($key -and $key.type -eq 'apiKey' -and $key.in -eq 'header' -and $key.name -eq 'x-api-key') ('{0}: apiKeyHeader is the x-api-key header' -f $file.Name)
    Check ($tok -and $tok.type -eq 'http' -and $tok.scheme -eq 'bearer') ('{0}: entraToken is an HTTP bearer token' -f $file.Name)
    $top = @($spec.security | ForEach-Object { $_.Keys }) -join ','
    Check ($top -eq 'apiKeyHeader,entraToken') ('{0}: top-level security is apiKeyHeader or entraToken' -f $file.Name)
    $overrides = @($spec.paths.Values | ForEach-Object { $_.Values } | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('security') }).Count
    Check ($overrides -eq 0) ('{0}: no operation overrides security' -f $file.Name)
}
foreach ($file in Get-ChildItem -Path $specDir -Filter '*.yaml') {
    # No YAML parser in PowerShell 7: check the text. Only the top-level security block may exist.
    $text = (Get-Content -Raw $file.FullName) -replace "`r`n", "`n"
    Check ($text -match "(?m)^security:\n  - apiKeyHeader: \[\]\n  - entraToken: \[\]\n(?!  )") ('{0}: top-level security is apiKeyHeader or entraToken' -f $file.Name)
    Check ([regex]::Matches($text, '(?m)^\s+security:').Count -eq 0) ('{0}: no operation overrides security' -f $file.Name)
    $block = [regex]::Match($text, "(?ms)^  securitySchemes:\n(.*?)(?=^  \S|\z)").Groups[1].Value
    $names = @([regex]::Matches($block, '(?m)^    (\w+):') | ForEach-Object { $_.Groups[1].Value }) -join ','
    Check ($names -eq 'apiKeyHeader,entraToken') ('{0}: declares exactly apiKeyHeader and entraToken' -f $file.Name)
    Check ($block -match "(?m)^      name: x-api-key$" -and $block -match "(?m)^      in: header$" -and $block -match "(?m)^      scheme: bearer$") ('{0}: apiKeyHeader is the x-api-key header, entraToken a bearer token' -f $file.Name)
}

[xml]$open = Get-Content -Raw (Join-Path $PolicyDir 'Product_EntraOpen_Policy.xml')
$validators = $open.SelectNodes('//validate-azure-ad-token')
Check ($validators.Count -eq 1) 'open product policy validates one kind of token (a person)'
Check ($validators[0].GetAttribute('tenant-id') -eq '__ENTRA_TENANT_ID__') 'it validates the tenant'
Check ($validators[0].audiences.audience -eq '__ENTRA_AUDIENCE__') 'it validates the audience'
Check ($validators[0].SelectNodes('.//claim[@name="scp"]/value').InnerText -eq '__ENTRA_SCOPE__') 'it requires the delegated scope (an app token has none)'
Check ($validators[0].SelectNodes('.//claim[@name="roles"]/value').InnerText -eq '__ENTRA_USER_ROLE__') 'it requires the user app role'
# A service must send key and token, so the open product refuses app tokens before validating.
$appBranch = $open.SelectSingleNode('//choose/when[contains(@condition, "callerIsApp")]')
Check (($null -ne $appBranch) -and ($appBranch.SelectSingleNode('return-response/set-status').code -eq '403') -and ($appBranch.SelectNodes('.//validate-azure-ad-token').Count -eq 0)) 'an app token is refused with 403, never validated or accepted'
Check (-not (Get-Content -Raw (Join-Path $PolicyDir 'Product_EntraOpen_Policy.xml')).Contains('__ENTRA_ROLE__')) 'the open product does not use the service app role'

# ---- compiled expressions ------------------------------------------------------------------
function MetaBody($xml, $name) {
    $v = ($xml.SelectNodes('//metadata') | Where-Object { $_.name -eq $name } | Select-Object -First 1).value.Trim()
    if ($v.StartsWith('@{') -and $v.EndsWith('}')) { return $v.Substring(2, $v.Length - 3) }
    if ($v.StartsWith('@(') -and $v.EndsWith(')')) { return 'return ' + $v.Substring(2, $v.Length - 3) + ';' }
    throw "metadata $name is not an expression"
}
$metaNames = @('RequestId', 'CallerType', 'CallerId', 'CallerName', 'Client', 'Api', 'Product', 'Model')
function Body($xml, $name) {
    $v = ($xml.SelectNodes('//set-variable') | Where-Object { $_.name -eq $name } | Select-Object -First 1).value.Trim()
    if ($v.StartsWith('@{') -and $v.EndsWith('}')) { return $v.Substring(2, $v.Length - 3) }
    if ($v.StartsWith('@(') -and $v.EndsWith(')')) { return 'return ' + $v.Substring(2, $v.Length - 3) + ';' }
    throw "$name is not an expression"
}
[xml]$anthropic = Get-Content -Raw (Join-Path $PolicyDir $inference[2])
[xml]$trace = '<r>' + ((Get-Content -Raw (Join-Path $PolicyDir 'UsageTrace_Fragment.xml')) -replace '<!--[\s\S]*?-->', '') + '</r>'
[xml]$reqlog = '<r>' + ((Get-Content -Raw (Join-Path $PolicyDir 'RequestBodyLog_Fragment.xml')) -replace '<!--[\s\S]*?-->', '') + '</r>'
function HeaderBody($xml, $name) {
    $v = ($xml.SelectNodes('//set-header') | Where-Object { $_.name -eq $name } | Select-Object -First 1).value.Trim()
    if ($v.StartsWith('@{') -and $v.EndsWith('}')) { return $v.Substring(2, $v.Length - 3) }
    if ($v.StartsWith('@(') -and $v.EndsWith(')')) { return 'return ' + $v.Substring(2, $v.Length - 3) + ';' }
    throw "header $name is not an expression"
}
function SetBodyCode($xml) {
    $v = $xml.SelectSingleNode('//set-body').InnerText.Trim()
    return $v.Substring(2, $v.Length - 3)
}
$code = @"
using System; using System.Collections.Generic; using System.Linq; using Newtonsoft.Json.Linq;
public class Hdrs { public Dictionary<string,string> d = new Dictionary<string,string>(); public string GetValueOrDefault(string k, string def){ return d.ContainsKey(k)? d[k]:def; } }
public class Bdy { public string text = ""; public T As<T>(bool preserveContent = false) { if (typeof(T)==typeof(JObject)) return (T)(object)JObject.Parse(text); if (typeof(T)==typeof(byte[])) return (T)(object)System.Text.Encoding.UTF8.GetBytes(text); throw new Exception("type"); } }
public class UrlInfo { public string Path = "/"; }
public class Req { public Hdrs Headers = new Hdrs(); public Bdy Body = new Bdy(); public UrlInfo Url = new UrlInfo(); }
public class Vars {
  public Dictionary<string,object> d = new Dictionary<string,object>();
  public T GetValueOrDefault<T>(string k, T def) { return d.ContainsKey(k) && d[k] is T ? (T)d[k] : def; }
  public object this[string k] { get { return d[k]; } }
}
public class Claims { public Dictionary<string,string> d = new Dictionary<string,string>(); public string GetValueOrDefault(string k, string def){ return d.ContainsKey(k)? d[k]:def; } }
public class Jwt { public Claims Claims = new Claims(); }
public class Sub { public string Id; public string Name; }
public class ApiInfo { public string Name = "Anthropic Service API"; }
public class ProdInfo { public string Id; }
public class Ctx { public Req Request = new Req(); public Vars Variables = new Vars(); public Sub Subscription; public ApiInfo Api = new ApiInfo(); public ProdInfo Product; public Guid RequestId = Guid.NewGuid(); }
public static class Ext {
  public static Jwt AsJwt(this string s) {
    try {
      var parts = s.Split('.');
      if (parts.Length != 3) return null;
      var p = parts[1].Replace('-', '+').Replace('_', '/');
      while (p.Length % 4 != 0) p += "=";
      var o = JObject.Parse(System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(p)));
      var j = new Jwt();
      foreach (var kv in o) { j.Claims.d[kv.Key] = kv.Value is JArray ? string.Join(",", ((JArray)kv.Value).Select(x => (string)x)) : (string)kv.Value; }
      return j;
    } catch { return null; }
  }
}
public static class Pol {
  public static object CallerIsApp(Ctx context) { $(Body $open 'callerIsApp') }
  public static object CallerId(Ctx context) { $(Body $open 'callerId') }
  public static object CallerClient(Ctx context) { $(Body $open 'callerClient') }
  public static object CallerName(Ctx context) { $(Body $open 'callerName') }
  public static object UsageId(Ctx context) { $(Body $anthropic 'usageId') }
  public static object UsageName(Ctx context) { $(Body $anthropic 'usageName') }
  public static object UsageModel(Ctx context) { $(Body $trace 'usageModel') }
  public static object StreamMeta(Ctx context) { $(HeaderBody $reqlog 'x-ms-meta-stream') }
  public static object LogContentType(Ctx context) { $(HeaderBody $reqlog 'x-ms-blob-content-type') }
  public static object LogBody(Ctx context) { $(SetBodyCode $reqlog) }
$(($metaNames | ForEach-Object { '  public static object Meta' + $_ + '(Ctx context) { ' + (MetaBody $trace $_) + ' }' }) -join "`n")
}
"@
$refs = @((Join-Path $PSHOME 'Newtonsoft.Json.dll'), 'System.Collections', 'System.Runtime', 'System.Text.RegularExpressions', 'System.Linq', 'System.Linq.Expressions', 'System.ComponentModel.TypeConverter', 'System.ObjectModel', 'System.Private.CoreLib', 'netstandard')
Add-Type -TypeDefinition $code -ReferencedAssemblies $refs -IgnoreWarnings

function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function Token($claims) { (B64 '{"alg":"none"}') + '.' + (B64 ($claims | ConvertTo-Json -Compress)) + '.sig' }
function Context($auth) {
    $c = New-Object Ctx
    if ($null -ne $auth) { $c.Request.Headers.d['Authorization'] = $auth }
    return $c
}
$oid = '3F2A9C10-AAAA-4BBB-8CCC-0123456789AB'
$user = Token @{ oid = $oid; name = 'Ada Lovelace'; azp = '11111111-1111-1111-1111-111111111111'; scp = 'access_as_user' }
$app = Token @{ oid = $oid; idtyp = 'app'; azp = '22222222-2222-2222-2222-222222222222'; azpacr = '2'; roles = @('Inference.Invoke') }

# Which branch the token takes.
Check ([Pol]::CallerIsApp((Context "Bearer $app")) -eq $true) 'app-only token is recognised (and refused)'
Check ([Pol]::CallerIsApp((Context "bearer $app")) -eq $true) 'the Bearer scheme is matched without regard to case'
Check ([Pol]::CallerIsApp((Context "Bearer $user")) -eq $false) 'delegated token takes the person branch'
Check ([Pol]::CallerIsApp((Context (('Bearer ' + (Token @{ oid = $oid; idtyp = 'user' }))))) -eq $false) 'idtyp user takes the person branch'
Check ([Pol]::CallerIsApp((Context $null)) -eq $false) 'no Authorization header takes the person branch (and then fails validation)'
Check ([Pol]::CallerIsApp((Context 'Bearer not.a.token')) -eq $false) 'garbage takes the person branch (and then fails validation)'
Check ([Pol]::CallerIsApp((Context "Basic $app")) -eq $false) 'a non-Bearer scheme is not read as a token'

# The caller named from a validated token.
function WithToken($t, $isApp) {
    $c = Context "Bearer $t"
    $c.Variables.d['callerJwt'] = ($t | ForEach-Object { [Ext]::AsJwt($_) })
    $c.Variables.d['callerIsApp'] = [bool]$isApp
    return $c
}
$c = WithToken $user $false
Check ([Pol]::CallerId($c) -eq $oid.ToLowerInvariant()) 'object id is read and lower-cased'
$c.Variables.d['callerId'] = [Pol]::CallerId($c)
Check ([Pol]::CallerClient($c) -eq '11111111-1111-1111-1111-111111111111') 'client app is azp'
$c.Variables.d['callerClient'] = [Pol]::CallerClient($c)
Check ([Pol]::CallerName($c) -eq 'Ada Lovelace') 'a person is named by the name claim'
Check ([Pol]::CallerId((WithToken (Token @{ name = 'x' }) $false)) -eq '') 'a token with no oid has no identity (the request is refused)'
Check ([Pol]::CallerId((WithToken (Token @{ oid = 'not-a-guid' }) $false)) -eq '') 'an oid that is not a GUID has no identity (the request is refused)'
Check ([Pol]::CallerId((WithToken (Token @{ oid = "$oid\nX" }) $false)) -eq '') 'an oid with extra text has no identity (the request is refused)'

function NameFor($claims, $isApp = $false) {
    $c = WithToken (Token $claims) $isApp
    $c.Variables.d['callerId'] = [Pol]::CallerId($c)
    $c.Variables.d['callerClient'] = [Pol]::CallerClient($c)
    return [Pol]::CallerName($c)
}
Check ((NameFor @{ oid = $oid; preferred_username = 'ada@example.org' }) -eq 'ada@example.org') 'without name, preferred_username is the name'
Check ((NameFor @{ oid = $oid }) -eq $oid.ToLowerInvariant()) 'with neither, the object id is the name'
Check ((NameFor @{ oid = $oid; name = "Ada`nLovelace`t" }) -eq 'Ada_Lovelace_') 'control characters in a name are replaced'
Check ((NameFor @{ oid = $oid; name = ('x' * 300) }).Length -eq 100) 'a long name is cut to 100 characters'

# Naming the caller in an inference policy: a key wins, a keyless request uses the caller.
$c = New-Object Ctx
$c.Subscription = New-Object Sub; $c.Subscription.Id = 'sub-oid'; $c.Subscription.Name = 'Grace Hopper'
$c.Variables.d['callerId'] = 'ignored'; $c.Variables.d['callerName'] = 'ignored'
Check (([Pol]::UsageId($c) -eq 'sub-oid') -and ([Pol]::UsageName($c) -eq 'Grace Hopper')) 'a keyed request is named by its subscription'
$c = New-Object Ctx
$c.Variables.d['callerId'] = $oid.ToLowerInvariant(); $c.Variables.d['callerName'] = 'Ada Lovelace'
Check (([Pol]::UsageId($c) -eq $oid.ToLowerInvariant()) -and ([Pol]::UsageName($c) -eq 'Ada Lovelace')) 'a keyless request is named by the token caller'
$c = New-Object Ctx
Check (([Pol]::UsageId($c) -eq '') -and ([Pol]::UsageName($c) -eq '')) 'no subscription and no caller gives an empty name (and does not throw)'

# The model in the usage record comes from the client.
$c = New-Object Ctx; $c.Variables.d['requestModel'] = 'claude sonnet`n<x>'
Check ([Pol]::UsageModel($c) -eq 'claude_sonnet_n_x_') 'a model name is limited to a safe character set'
$c = New-Object Ctx; $c.Variables.d['requestModel'] = ('m' * 200)
Check ([Pol]::UsageModel($c).Length -eq 64) 'a long model name is cut to 64 characters'
$c = New-Object Ctx; $c.Variables.d['deploymentName'] = 'gpt-5'
Check ([Pol]::UsageModel($c) -eq 'gpt-5') 'the deployment name is the fallback model'
$c = New-Object Ctx
Check ([Pol]::UsageModel($c) -eq '-') 'no model gives a dash, never an empty value'

# Request body log: the stream flag comes from requestIsStream (Anthropic) or the JSON body (the others).
function StreamCase($var, $ctype, $body) {
    $c = New-Object Ctx
    if ($null -ne $var) { $c.Variables.d['requestIsStream'] = $var }
    $c.Request.Headers.d['Content-Type'] = $ctype
    $c.Request.Body.text = $body
    return [Pol]::StreamMeta($c)
}
Check ((StreamCase 'true' 'application/json' '{}') -eq 'true') 'request log stream: requestIsStream is used when set'
Check ((StreamCase $null 'application/json' '{"stream":true}') -eq 'true') 'request log stream: JSON body with stream true'
Check ((StreamCase $null 'application/json; charset=utf-8' '{"model":"m"}') -eq 'false') 'request log stream: JSON body without stream'
Check ((StreamCase $null 'multipart/form-data; boundary=x' '--x--') -eq '-') 'request log stream: not JSON gives a dash'
Check ((StreamCase $null 'application/json' 'not json') -eq '-') 'request log stream: unreadable JSON gives a dash'

# Every trace metadata value must be non-empty: APIM answers 500 (ExpressionValueValidationFailure,
# "The value field is required") when one is empty, and that happened to every keyed request on dev.
function MetaValues($c) {
    $c.Variables.d['usageModel'] = [Pol]::UsageModel($c)
    $o = @{}
    foreach ($n in $metaNames) { $o[$n] = [Pol]::('Meta' + $n).Invoke($c) }
    return $o
}
function AllNonEmpty($o) { foreach ($n in $metaNames) { if ([string]::IsNullOrEmpty([string]$o[$n])) { return $false } }; return $true }
# a keyed request: no caller variables at all, no client
$c = New-Object Ctx; $c.Subscription = New-Object Sub; $c.Subscription.Id = 'sub-oid'; $c.Subscription.Name = 'Grace Hopper'
$c.Product = New-Object ProdInfo; $c.Product.Id = 'nsls2aifapim'; $c.Variables.d['requestModel'] = 'gpt-4.1'
$c.Variables.d['usageId'] = [Pol]::UsageId($c); $c.Variables.d['usageName'] = [Pol]::UsageName($c)
$m = MetaValues $c
Check (AllNonEmpty $m) 'trace metadata, keyed request: no value is empty'
Check (($m['CallerType'] -eq 'key') -and ($m['Client'] -eq '-') -and ($m['CallerName'] -eq 'Grace Hopper')) 'trace metadata, keyed request: key type, no client, subscription name'
# a keyless request through the open product
$c = New-Object Ctx; $c.Product = New-Object ProdInfo; $c.Product.Id = 'nsls2aifapim-open'; $c.Variables.d['requestModel'] = 'claude-auto'
$c.Variables.d['callerId'] = $oid.ToLowerInvariant(); $c.Variables.d['callerName'] = 'Ada Lovelace'; $c.Variables.d['callerType'] = 'user'
$c.Variables.d['callerClient'] = '11111111-1111-1111-1111-111111111111'
$c.Variables.d['usageId'] = [Pol]::UsageId($c); $c.Variables.d['usageName'] = [Pol]::UsageName($c)
$m = MetaValues $c
Check (AllNonEmpty $m) 'trace metadata, keyless request: no value is empty'
Check (($m['CallerType'] -eq 'user') -and ($m['CallerId'] -eq $oid.ToLowerInvariant()) -and ($m['Product'] -eq 'nsls2aifapim-open') -and ($m['Model'] -eq 'claude-auto')) 'trace metadata, keyless request: caller, product and model are recorded'
# nothing known: a model listing with no model, no product, no caller
$c = New-Object Ctx
$m = MetaValues $c
Check (AllNonEmpty $m) 'trace metadata, nothing set: no value is empty (a dash is used)'

# The request body log keeps a text body as it is, and replaces an audio upload by one line.
$c = New-Object Ctx; $c.Request.Url.Path = '/openai/v1/responses'; $c.Request.Headers.d['Content-Type'] = 'application/json'; $c.Request.Body.text = '{"model":"gpt-5"}'
Check (([Text.Encoding]::UTF8.GetString([Pol]::LogBody($c)) -eq '{"model":"gpt-5"}') -and ([Pol]::LogContentType($c) -eq 'application/json')) 'request body log: a JSON body is stored as sent'
$c = New-Object Ctx; $c.Request.Url.Path = '/deployments/gpt-transcribe/audio/transcriptions'; $c.Request.Headers.d['Content-Type'] = 'multipart/form-data; boundary=x'
$c.Request.Headers.d['Content-Length'] = '3500000'; $c.Request.Body.text = 'SECRET-AUDIO-BYTES'
$stored = [Text.Encoding]::UTF8.GetString([Pol]::LogBody($c))
Check (($stored -eq 'audio upload not stored, content-length=3500000') -and ([Pol]::LogContentType($c) -eq 'text/plain')) 'request body log: an audio upload is replaced by its size'
$c.Request.Url.Path = '/deployments/gpt-4o-transcribe/audio/transcriptions'; $c.Request.Headers.d['Content-Length'] = "12`r`nX: y"
Check ([Text.Encoding]::UTF8.GetString([Pol]::LogBody($c)) -eq 'audio upload not stored, content-length=12') 'request body log: the declared size is reduced to digits'
$c.Request.Headers.d.Remove('Content-Length')
Check ([Text.Encoding]::UTF8.GetString([Pol]::LogBody($c)) -eq 'audio upload not stored, content-length=-') 'request body log: no declared size gives a dash'

"failures: $bad"
if ($bad -gt 0) { exit 1 }
