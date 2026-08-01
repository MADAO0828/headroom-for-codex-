$ErrorActionPreference='Stop'
$rule=Get-NetFirewallRule -DisplayName 'Headroom 18787' -ErrorAction SilentlyContinue
if($null -eq $rule){'missing'; exit 0}
$port=@($rule | Get-NetFirewallPortFilter -ErrorAction Stop)
if($port.Count -ne 1 -or [string]$port[0].Protocol -ne 'TCP' -or [string]$port[0].LocalPort -ne '18787' -or [string]$rule.Direction -ne 'Inbound' -or [string]$rule.Action -ne 'Allow'){throw 'firewall_rule_ambiguous'}
Remove-NetFirewallRule -DisplayName 'Headroom 18787'
if(Get-NetFirewallRule -DisplayName 'Headroom 18787' -ErrorAction SilentlyContinue){throw 'firewall_rule_still_present'}
'removed'