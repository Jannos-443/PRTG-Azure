<#
    .SYNOPSIS
    Monitors Azure TrafficManager Profiles

    .DESCRIPTION
    Using Microsoft API to Monitor TrafficManager Profiles
    You can

    Copy this script to the PRTG probe EXEXML scripts folder (${env:ProgramFiles(x86)}\PRTG Network Monitor\Custom Sensors\EXEXML)
    and create a "EXE/Script Advanced. Choose this script from the dropdown and set at least:

    + Parameters: TenatId, ApplicationId, AccessSecret
    + Scanning Interval: minimum 15 minutes

    .PARAMETER TenantId
    Provide TenantId

    .PARAMETER ApplicationID
    Provide the ApplicationID

    .PARAMETER AccessSecret
    Provide the Application Secret

    .PARAMETER SubscriptionId
    Provide the SubscriptionId

    .PARAMETER resourceGroupName
    Optional: Provide resourceGroupName

    .PARAMETER ExcludeProfileName
    Regular expression to describe the ProfileName for Example "Test" to exclude it

    Example: ^(ProfileTest|Test2)$

    Example2: ^(Test123.*|Test555)$ excludes Test123, Test1234, Test12345 and Test555

    #https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_regular_expressions?view=powershell-7.1

    .PARAMETER IncludeProfileName
    Regular expression to describe a ProfileName to include

    .EXAMPLE
    Sample call from PRTG EXE/Script Advanced

    "PRTG-Azure-TrafficManager.ps1" -ApplicationID 'Test-APPID' -TenantId 'Test-TenantId' -AccessSecret 'Test-AppSecret' -SubscriptionId 'xxx...xxx'

    Author:  Jannos-443
    https://github.com/Jannos-443/PRTG-Azure
#>
param(
    [string] $TenantId = '',
    [string] $ApplicationID = '',
    [string] $AccessSecret = '',
    [string] $SubscriptionId = '',
    [string] $profileName = '',
    [string] $resourceGroupName = '',
    [string] $ExcludeProfileName = '',
    [string] $IncludeProfileName = '',
    [switch] $UseFQDN = $false
)

#Catch all unhandled Errors
$ErrorActionPreference = "Stop"
trap {
    $Output = "line:$($_.InvocationInfo.ScriptLineNumber.ToString()) char:$($_.InvocationInfo.OffsetInLine.ToString()) --- message: $($_.Exception.Message.ToString()) --- line: $($_.InvocationInfo.Line.ToString()) "
    $Output = $Output.Replace("<", "")
    $Output = $Output.Replace(">", "")
    $Output = $Output.Replace("#", "")
    Write-Output "<prtg>"
    Write-Output "<error>1</error>"
    Write-Output "<text>$Output</text>"
    Write-Output "</prtg>"
    Exit
}

if (($TenantId -eq "") -or ($Null -eq $TenantId)) {
    Throw "TenantId Variable is empty"
}

if (($ApplicationID -eq "") -or ($Null -eq $ApplicationID)) {
    Throw "ApplicationID Variable is empty"
}

if (($AccessSecret -eq "") -or ($Null -eq $AccessSecret)) {
    Throw "AccessSecret Variable is empty"
}

if (($SubscriptionId -eq "") -or ($Null -eq $SubscriptionId)) {
    Throw "SubscriptionId Variable is empty"
}

#region Get Access Token
try {
    #Check if Token is expired
    $renew = $false

    if ($ConnectGraph) {
        if ((Get-Date).AddMinutes(2) -ge $tokenexpire) {
            Write-Host "Token expired or close to expire, going to renew Token"
            $renew = $true
        }

        else {
            Write-Host "Token found and still valid"
        }
    }

    else {
        $renew = $true
        Write-Host "Token not found, going to renew Token"
    }

    $Resource = "https://management.core.windows.net/"
    $RequestAccessTokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
    #"https://login.microsoftonline.com/$TenatDomainName/oauth2/v2.0/token"

    if ($renew) {
        #Request Token
        $Body = @{
            Grant_Type    = "client_credentials"
            resource      = $Resource
            client_Id     = $ApplicationID
            Client_Secret = $AccessSecret
        }

        $ConnectGraph = Invoke-RestMethod -Uri $RequestAccessTokenUri -Method POST -Body $Body
        $Token = $ConnectGraph.access_token
        $tokenexpire = (Get-Date).AddSeconds($ConnectGraph.expires_in)

        Write-Output "Access Token JSON"
        #Write-Output $Token
    }
}

catch {
    Write-Output "<prtg>"
    Write-Output " <error>1</error>"
    Write-Output " <text>Error getting Access Token ($($_.Exception.Message))</text>"
    Write-Output "</prtg>"
    Exit
}

$xmlOutput = '<prtg>'
#endregion

#Function API Call
Function GraphCall($URL) {
    #MS Graph Request
    try {
        $Headers = @{Authorization = "$($ConnectGraph.token_type) $($ConnectGraph.access_token)" }
        $GraphUrl = $URL
        $Result_Part = Invoke-RestMethod -Headers $Headers -Uri $GraphUrl -Method Get
        $Result = $Result_Part.value
        while ($Result_Part.'@odata.nextLink') {
            $graphURL = $Result_Part.'@odata.nextLink'
            $Result_Part = Invoke-RestMethod -Headers $Headers -Uri $GraphUrl -Method Get
            $Result = $Result + $Result_Part.value
        }
    }

    catch {
        Write-Output "<prtg>"
        Write-Output " <error>1</error>"
        Write-Output " <text>Could not MS Graph $($GraphUrl). Error: $($_.Exception.Message)</text>"
        Write-Output "</prtg>"
        Exit
    }
    return $Result
}

#region Get Profiles
#https://docs.microsoft.com/en-us/rest/api/trafficmanager/profiles/get#profile-get-withendpoints
if (($profileName) -and ($resourceGroupName)) {
    $Result = GraphCall -URL "https://management.azure.com/subscriptions/$($SubscriptionId)/resourceGroups/$($resourceGroupName)/providers/Microsoft.Network/trafficmanagerprofiles/$($profileName)?api-version=2018-04-01"

}
elseif ($resourceGroupName) {
    $Result = GraphCall -URL "https://management.azure.com/subscriptions/$($SubscriptionId)/resourceGroups/$($resourceGroupName)/providers/Microsoft.Network/trafficmanagerprofiles?api-version=2018-04-01"

}
else {
    $Result = GraphCall -URL "https://management.azure.com/subscriptions/$($SubscriptionId)/providers/Microsoft.Network/trafficmanagerprofiles?api-version=2018-04-01"

}
#endregion

#region Filter
if ($ExcludeProfileName -ne "") {
    $Result = $Result | Where-Object {$_.Name -notmatch $ExcludeProfileName}
}

if ($IncludeProfileName -ne "") {
    $Result = $Result | Where-Object {$_.Name -match $IncludeProfileName}
}
#endregion

#region Check Results
if($null -eq $Result)
    {
    Throw "no profile found, check parameters"
    }
#endregion

#region Format Output
$OutputText = ""
foreach ($currentItemName in $Result) {
    $TpName = $currentItemName.name

    if ($UseFQDN) {
        $TpName = $currentItemName.properties.dnsConfig.fqdn
    }

    $ProfileStatus = $currentItemName.properties.profileStatus
    switch ($ProfileStatus) {
        "Enabled" { $profileStatusSwitch = 0 }
        "Disabled" { $profileStatusSwitch = 1 }
    }

    $profileMonitorStatus = $currentItemName.properties.monitorConfig.profileMonitorStatus
    switch ($profileMonitorStatus) {
        "Online" { $profileMonitorStatusSwitch = 0 }
        "Disabled" { $profileMonitorStatusSwitch = 1 }
        "Degraded" { $profileMonitorStatusSwitch = 2 }
        "Inactive" { $profileMonitorStatusSwitch = 3 }
        "CheckingEndpoints" { $profileMonitorStatusSwitch = 4 }
        "Failed" { $profileMonitorStatusSwitch = 5 }
        else { $profileMonitorStatusSwitch = -1 }
    }

    $TpEndpointsDegraded = $currentItemName.properties.endpoints | Where-Object { $_.properties.endpointMonitorStatus -eq "Degraded" }
    $TpEndpointsOnline = $currentItemName.properties.endpoints | Where-Object { $_.properties.endpointMonitorStatus -eq "Online" }

    if (($profileMonitorStatusSwitch -eq 2) -and ($TpEndpointsOnline.count -eq 0)) {
        $profileMonitorStatusSwitch = 5
    }

    if ($TpEndpointsDegraded.count -gt 0) {
        foreach ($Endpoint in $TpEndpointsDegraded) {
            $OutputText += "$($Endpoint.name); "
        }
        $OutputText = $OutputText.Insert(0, "$($profileName) Offline: ")
    }

    else {
        foreach ($Endpoint in $TpEndpointsOnline) {
            $OutputText += "$($Endpoint.name); "
        }
        $OutputText = $OutputText.Insert(0, "$($profileName) Online: ")
    }



    #Output
    if ($profileName) {
        $xmlOutput += "<text>$($OutputText)</text>"

        $xmlOutput += "<result>
            <channel>profileStatus</channel>
            <value>$($profileStatusSwitch)</value>
            <unit>Custom</unit>
            <CustomUnit>Status</CustomUnit>
            <valuelookup>prtg.azure.trafficmanager.profilestatus</valuelookup>
            </result>
            <result>
            <channel>profileMonitorStatus</channel>
            <value>$($profileMonitorStatusSwitch)</value>
            <unit>Custom</unit>
            <CustomUnit>Status</CustomUnit>
            <valuelookup>prtg.azure.trafficmanager.monitorstatus</valuelookup>
            </result>
            <result>
            <channel>Endpoints Online</channel>
            <value>$($TpEndpointsOnline.count)</value>
            <unit>Count</unit>
            <limitmode>1</limitmode>
            <LimitMinError>0</LimitMinError>
            </result>
            <result>
            <channel>Endpoints Degraded</channel>
            <value>$($TpEndpointsDegraded.count)</value>
            <unit>Count</unit>
            <limitmode>1</limitmode>
            <LimitMaxWarning>1</LimitMaxWarning>
            </result>"
    }
    else {
        $xmlOutput += "<result>
                <channel>$($TpName)</channel>
                <value>$($profileMonitorStatusSwitch)</value>
                <unit>Custom</unit>
                <CustomUnit>Status</CustomUnit>
                <valuelookup>prtg.azure.trafficmanager.monitorstatus</valuelookup>
                </result>"
    }
}
#endregion

#region PRTG Output
$xmlOutput = $xmlOutput + "</prtg>"

$xmlOutput
#endregion