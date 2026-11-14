# Compiles the real expressions of the MAI image policy (read from the policy XML) against a
# fake APIM context and runs the multipart and JSON cases of mai-cases.json through them:
# which requests the policy refuses for web_grounding, and which model name it records.
# It needs PowerShell 7 (pwsh), which has the C# compiler and Newtonsoft.Json. It does not
# run APIM, so APIM's own limits on allowed types are not checked.
#
#   pwsh -NoProfile -File tests/policy/mai-policy-test.ps1
#
# Exit status 1 when a case fails.
param(
    [string]$Policy = (Join-Path $PSScriptRoot '../../apim_policies/MAI_Image_Policy-Managed_Identity_with_Retry.xml'),
    [string]$CasesFile = (Join-Path $PSScriptRoot 'mai-cases.json'),
    [string]$V1Policy = (Join-Path $PSScriptRoot '../../apim_policies/OpenAIv1Messages_Policy-Managed_Identity_with_Retry_MultiRegion.xml')
)
$WarningPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# APIM allows only some members of some types in a policy expression, and the C# compiler here
# knows nothing about that list. The documented members of Regex are the ones below; one that is
# not listed (for example Regex.Escape) fails the deployment with a ValidationError. Check every
# policy file for it before running the cases.
$allowedRegex = @('IsMatch', 'Match', 'Matches', 'Replace', 'Unescape', 'Split')
$policyDir = Split-Path -Parent $Policy
$regexBad = 0
foreach ($file in Get-ChildItem -Path $policyDir -Filter '*.xml') {
    $text = Get-Content -Raw $file.FullName
    foreach ($m in [regex]::Matches($text, 'RegularExpressions\.Regex\.(\w+)')) {
        if ($allowedRegex -notcontains $m.Groups[1].Value) {
            $regexBad++
            'NOT ALLOWED  {0}: Regex.{1} is not an APIM-allowed member' -f $file.Name, $m.Groups[1].Value
        }
    }
}
[xml]$x = Get-Content -Raw $Policy
[xml]$x1 = Get-Content -Raw $V1Policy
function Expr($name, $doc = $x) {
    $v = ($doc.SelectNodes("//set-variable") | Where-Object { $_.name -eq $name }).value.Trim()
    if (-not ($v.StartsWith('@{') -and $v.EndsWith('}'))) { throw "$name is not a block expression" }
    return $v.Substring(2, $v.Length - 3)
}
# The OpenAI v1 policy reads image edit forms with the same reader; it must not drift.
$sameReader = (Expr 'formFields') -eq (Expr 'formFields' $x1)
'{0,-6} {1}' -f $(if ($sameReader) { 'OK' } else { 'WRONG' }), 'OpenAI v1 policy formFields is identical to the MAI one'
$code = @"
using System; using System.Collections.Generic; using Newtonsoft.Json.Linq;
public class Hdrs { public Dictionary<string,string> d = new Dictionary<string,string>(); public string GetValueOrDefault(string k, string def){ return d.ContainsKey(k)? d[k]:def; } }
public class Bdy { public string text; public T As<T>(bool preserveContent = false) { if (typeof(T)==typeof(string)) return (T)(object)text; if (typeof(T)==typeof(JObject)) return (T)(object)JObject.Parse(text); throw new Exception("type"); } }
public class Req { public Hdrs Headers = new Hdrs(); public Bdy Body = new Bdy(); }
public class Vars { public Dictionary<string,object> d = new Dictionary<string,object>(); public T GetValueOrDefault<T>(string k, T def) { return d.ContainsKey(k) && d[k] is T ? (T)d[k] : def; } }
public class Ctx { public Req Request = new Req(); public Vars Variables = new Vars(); }
public static class Pol {
  public static object FormFields(Ctx context) { $(Expr 'formFields') }
  public static object Model(Ctx context) { $(Expr 'requestModel') }
  public static object Grounding(Ctx context) { $(Expr 'webGrounding') }
  public static object V1Model(Ctx context) { $(Expr 'requestModel' $x1) }
}
"@
$refs = @((Join-Path $PSHOME 'Newtonsoft.Json.dll'), 'System.Collections', 'System.Runtime', 'System.Text.RegularExpressions', 'System.Linq', 'System.Private.CoreLib', 'netstandard')
Add-Type -TypeDefinition $code -ReferencedAssemblies $refs -IgnoreWarnings
$cases = Get-Content -Raw $CasesFile | ConvertFrom-Json
$bad = 0
foreach ($c in $cases) {
    $ctx = New-Object Ctx
    $ctx.Request.Headers.d['Content-Type'] = $c.contentType
    $ctx.Request.Headers.d['Content-Length'] = '1000'
    $ctx.Request.Body.text = $c.body
    $ctx.Variables.d['formFields'] = [Pol]::FormFields($ctx)
    $blocked = [Pol]::Grounding($ctx)
    $model = [Pol]::Model($ctx)
    $ok = ($blocked -eq $c.blocked) -and ($model -eq $c.model)
    # The v1 policy names a multipart model the same way (it has no size limit or web_grounding).
    if ($c.contentType -like 'multipart/*') {
        $v1Model = [Pol]::V1Model($ctx)
        $ok = $ok -and ($v1Model -eq $c.model)
    } else { $v1Model = '-' }
    if (-not $ok) { $bad++ }
    '{0,-6} {1,-50} blocked={2,-5} model={3} v1={4}' -f $(if ($ok) { 'OK' } else { 'WRONG' }), $c.name, $blocked, $model, $v1Model
}
if (-not $sameReader) { $bad++ }
"failures: $bad of $($cases.Count); disallowed Regex members: $regexBad"
if (($bad + $regexBad) -gt 0) { exit 1 }
