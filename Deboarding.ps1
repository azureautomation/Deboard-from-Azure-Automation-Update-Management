<#
    .SYNOPSIS
        This runbook is intended to help customers remove updates solution from their log analytics workspace linked to the automation account and disables schedules associated with software update configurations.

    .DESCRIPTION
        This runbook will disable the schedules associated with the software update configurations to further ensure that the Runbook Patch-MicrosoftOMSComputers is not triggered.
        It will also remove updates solution from their log analytics workspace linked to the automation account. 
        This will also ensure that system hybrid workers used for Azure Automation Update Management under this automation account stops sending pings and eventually post 30 days they will be deleted automatically.

    .PARAMETER AutomationAccountResourceId
        Mandatory
        Automation Account Resource Id.

    .PARAMETER UserManagedServiceIdentityClientId
        Mandatory
        Client Id of the User Assigned Managed Idenitity.
        
    .EXAMPLE
        Deboarding -AutomationAccountResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}"  -ClientId "########-####-####-####-############"

    .OUTPUTS
        The count of software update configurations disabled.
        Status of removing updates solution from linked log analytics workspace of the automation account.
#>
param(

    [Parameter(Mandatory = $true)]
    [String]$AutomationAccountResourceId,

    [Parameter(Mandatory = $true)]
    [String]$UserManagedServiceIdentityClientId
)

# Telemetry level.
$Debug = "Debug"
$Verbose = "Verbose" 
$Informational = "Informational"
$Warning = "Warning" 
$ErrorLvl = "Error"

$Succeeded = "Succeeded"
$Failed = "Failed"

# Master runbook name
$MasterRunbookName = "Patch-MicrosoftOMSComputers"

# API versions.
$AutomationApiVersion = "2022-08-08"
$WorkspaceApiVersion = "2022-10-01"
$SolutionsApiVersion = "2015-11-01-preview"
$SoftwareUpdateConfigurationApiVersion = "2023-11-01";
$AutomationAccountApiVersion = "2023-11-01";

# ARM endpoints.
$LinkedWorkspacePath = "{0}/linkedWorkspace"
$SolutionsWithWorkspaceFilterPath = "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.OperationsManagement/solutions?`$filter=properties/workspaceResourceId%20eq%20'{2}'"
$SoftwareUpdateConfigurationsPath = "{0}/softwareUpdateConfigurations"
$JobSchedulesWithPatchRunbookFilterPath = "{0}/JobSchedules/?$filter=properties/runbook/name%20eq%20'Patch-MicrosoftOMSComputers'&`$skip={1}"
$AutomationSchedulesPath = "{0}/Schedules/{1}"

# HTTP methods.
$GET = "GET"
$PATCH = "PATCH"
$PUT = "PUT"
$POST = "POST"
$DELETE = "DELETE"

# Validation values.
$HttpMethods = @($GET, $PATCH, $POST, $PUT, $DELETE)
$TelemetryLevels = @($Debug, $Verbose, $Informational, $Warning, $ErrorLvl)

#Max depth of payload.
$MaxDepth = 5

# Beginning of Payloads.
$DisableAutomationSchedule = @"
{
    "properties": 
    {
        "isEnabled": false
    }
}
"@
# End of Payloads.

$Global:JobSchedules = @{}
$Global:SoftwareUpdateConfigurationsResourceIDs = @{}
$Global:SoftwareUpdateConfigurationsDisabledStatus = @{}
$Global:UpdatesSolutionRemoved = $false

function Write-Telemetry
{
    <#
    .Synopsis
        Writes telemetry to the job logs.
        Telemetry levels can be "Informational", "Warning", "Error" or "Verbose".
    
    .PARAMETER Message
		Log message to be written.
    
    .PARAMETER Level
        Log level.

    .EXAMPLE
        Write-Telemetry -Message Message -Level Level.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 1)]
        [String]$Message,

        [Parameter(Mandatory = $false, Position = 2)]
        [ValidateScript({ $_ -in $TelemetryLevels })]
        [String]$Level = $Informational
    )

    if ($Level -eq $Warning)
    {
        Write-Warning $Message
    }
    elseif ($Level -eq $ErrorLvl)
    {
        Write-Error $Message
    }
    else
    {
        Write-Verbose $Message -Verbose
    }
}

function Parse-ArmId
{
    <#
		.SYNOPSIS
			Parses ARM resource id.
	
		.DESCRIPTION
			This function parses ARM id to return subscription, resource group, resource name, etc.
	
		.PARAMETER ResourceId
			ARM resourceId of the machine.		
	
		.EXAMPLE
			Parse-ArmId -ResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}"
	#>
    param(
        [Parameter(Mandatory = $true, Position = 1)]
        [String]$ResourceId
    )

    $parts = $ResourceId.Split("/")
    return @{
        Subscription = $parts[2]
        ResourceGroup = $parts[4]
        ResourceProvider = $parts[6]
        ResourceType = $parts[7]
        ResourceName = $parts[8]
    }
}

function Invoke-AzRestApiWithRetry
{
   <#
		.SYNOPSIS
			Wrapper around Invoke-AzRestMethod.
	
		.DESCRIPTION
			This function calls Invoke-AzRestMethod with retries.
	
		.PARAMETER Params
			Parameters to the cmdlet.

        .PARAMETER Payload
			Payload.

		.PARAMETER Retry
			Number of retries to attempt.
	
		.PARAMETER Delay
			The maximum delay (in seconds) between each attempt. The default is 5 seconds.
            
		.EXAMPLE
			Invoke-AzRestApiWithRetry -Params @{SubscriptionId = "xxxx" ResourceGroup = "rgName" ResourceName = "resourceName" ResourceProvider = "Microsoft.Compute" ResourceType = "virtualMachines"} -Payload "{'location': 'westeurope'}"
	#>
	[CmdletBinding()]
	Param
	(
		[Parameter(Mandatory = $true, Position = 1)]
		[System.Collections.Hashtable]$Params,

        [Parameter(Mandatory = $false, Position = 2)]
		[Object]$Payload = $null,

        [Parameter(Mandatory = $false, Position = 3)]
		[ValidateRange(0, [UInt32]::MaxValue)]
		[UInt32]$Retry = 3,
	
		[Parameter(Mandatory = $false, Position = 4)]
		[ValidateRange(0, [UInt32]::MaxValue)]
		[UInt32]$Delay = 5
	)

    if ($Payload)
    {
        [void]$Params.Add('Payload', $Payload)
    }

    $retriableErrorCodes = @(409, 429)
		
    for ($i = 0; $i -lt $Retry; $i++)
    {
        $exceptionMessage = ""
        $paramsString = $Params | ConvertTo-Json -Compress -Depth $MaxDepth | ConvertFrom-Json
        try
        {
            Write-Telemetry -Message ("[Debug]Invoke-AzRestMethod started with params [{0}]. Retry: {1}." -f $paramsString, ($i+1) + $ForwardSlashSeparator + $Retry)
            $output = Invoke-AzRestMethod @Params -ErrorAction Stop
            $outputString = $output | ConvertTo-Json -Compress -Depth $MaxDepth | ConvertFrom-Json
            if ($retriableErrorCodes.Contains($output.StatusCode) -or $output.StatusCode -ge 500)
            {
                if ($i -eq ($Retry - 1))
                {
                    $message = ("[Debug]Invoke-AzRestMethod with params [{0}] failed even after [{1}] retries. Failure reason:{2}." -f $paramsString, $Retry, $outputString)
                    Write-Telemetry -Message $message -Level $ErrorLvl
                    return Process-ApiResponse -Response $output
                }

                $exponential = [math]::Pow(2, ($i+1))
                $retryDelaySeconds = ($exponential - 1) * $Delay  # Exponential Backoff Max == (2^n)-1
                Write-Telemetry -Message ("[Debug]Invoke-AzRestMethod with params [{0}] failed with retriable error code. Retrying in {1} seconds, Failure reason:{2}." -f $paramsString, $retryDelaySeconds, $outputString) -Level $Warning
                Start-Sleep -Seconds $retryDelaySeconds
            }
            else
            {
                Write-Telemetry -Message ("[Debug]Invoke-AzRestMethod with params [{0}] succeeded. Output: [{1}]." -f $paramsString, $outputString)
                return Process-ApiResponse -Response $output
            }
        }
        catch [Exception]
        {
            $exceptionMessage = $_.Exception.Message
            Write-Telemetry -Message ("[Debug]Invoke-AzRestMethod with params [{0}] failed with an unhandled exception: {1}." -f $paramsString, $exceptionMessage) -Level $ErrorLvl
            throw
        }
    }   
}

function Invoke-ArmApi-WithPath
{
   <#
		.SYNOPSIS
			Wrapper around Invoke-AzRestMethod.
	
		.DESCRIPTION
			This function calls Invoke-AzRestMethod with retries with a path.
	
		.PARAMETER Path
			ARM API path.

        .PARAMETER ApiVersion
			API version.

        .PARAMETER Method
			HTTP method.

        .PARAMETER Payload
			Paylod for API call.
	
		.EXAMPLE
			Invoke-ArmApi-WithPath -Path "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Compute/virtualMachines/{vmName}/start" -ApiVersion "2023-03-01" -method "PATCH" -Payload "{'location': 'westeurope'}"
	#>
	[CmdletBinding()]
	Param
	(
		[Parameter(Mandatory = $true, Position = 1)]
		[String]$Path,

        [Parameter(Mandatory = $true, Position = 2)]
		[String]$ApiVersion,

        [Parameter(Mandatory = $true, Position = 3)]
        [ValidateScript({ $_ -in $HttpMethods })]
		[String]$Method,

        [Parameter(Mandatory = $false, Position =4)]
		[Object]$Payload = $null
	)

    $PathWithVersion = "{0}?api-version={1}"
    if ($Path.Contains("?"))
    {
        $PathWithVersion = "{0}&api-version={1}"
    }

    $Uri = ($PathWithVersion -f $Path, $ApiVersion) 
    $Params = @{
        Path = $Uri
        Method = $Method
    }

    return Invoke-AzRestApiWithRetry -Params $Params -Payload $Payload   
}

function Process-ApiResponse
{
    <#
		.SYNOPSIS
			Process API response and returns data.
	
		.PARAMETER Response
			Response object.
	
		.EXAMPLE
			Process-ApiResponse -Response {"StatusCode": 200, "Content": "{\"properties\": {\"location\": \"westeurope\"}}" }
	#>
	[CmdletBinding()]
	Param
	(
		[Parameter(Mandatory = $true, Position = 1)]
		[Object]$Response
	)

    $content = $null
    if ($Response.Content)
    {
        $content = ConvertFrom-Json $Response.Content
    }

    if ($Response.StatusCode -eq 200)
    {
        return @{ 
            Status = $Succeeded
            Response = $content
            ErrorCode = [String]::Empty 
            ErrorMessage = [String]::Empty
            }
    }
    else
    {
        $errorCode = $Unknown
        $errorMessage = $Unknown
        if ($content.error)
        {
            $errorCode = ("{0}/{1}" -f $Response.StatusCode, $content.error.code)
            $errorMessage = $content.error.message
        }

        return @{ 
            Status = $Failed
            Response = $content
            ErrorCode = $errorCode  
            ErrorMessage = $errorMessage
            }
    }
}

function Initialize-JobSchedules
{
   <#
		.SYNOPSIS
			Gets schedules associated with Update Management master runbook and maintains a global list.
	
		.DESCRIPTION
			This command will get & maintain a global list of UM schedules with support for pagination.

        .PARAMETER AutomationAccountResourceId
			Automation Account Resource Id.

		.EXAMPLE
			Initialize-JobSchedules -AutomationAccountResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}"
	#>
	[CmdletBinding()]
	Param
	(
        [Parameter(Mandatory = $true, Position = 1)]
		[String]$AutomationAccountResourceId
	)
    $output = $null
    $skip = 0
    do
    {
        $path = ($JobSchedulesWithPatchRunbookFilterPath -f $AutomationAccountResourceId, $skip)
        $output = Invoke-ArmApi-WithPath -Path $path -ApiVersion $AutomationAccountApiVersion -Method $GET
        if($output.Status -eq $Failed)
        {
            Write-Telemetry -Message ("Failed to get schedules with error code {0} and error message {1}." -f $output.ErrorCode, $output.ErrorMessage)
            throw
        }
        foreach ($result in $output.Response.value)
        {
            $properties = $result.properties
            if ($properties.runbook.name -eq $MasterRunbookName)
            {
                $parts = $properties.schedule.name.Split("_")
                $sucName = $parts[0 .. ($parts.Length - 2)] -join "_"
                if (!$Global:JobSchedules.ContainsKey($sucName))
                {
                    $Global:JobSchedules[$sucName] = [System.Collections.Generic.HashSet[String]]@()
                }
    
                [void]$Global:JobSchedules[$sucName].Add($properties.schedule.name)
            }
        }
        # API paginates in multiples of 100.
        $skip = $skip + 100
    }
    while ($null -ne $output.Response.nextLink);
}

function Disable-SoftwareUpdateConfiguration
{
   <#
		.SYNOPSIS
			Disables schedule associated with the Software Update Configuration.
	
		.DESCRIPTION
			This command will disable schedule associated with SUC.

        .PARAMETER AutomationAccountResourceId
			Automation Account Id.
        
        .PARAMETER ScheduleName
			Schedule name.

        .PARAMETER SoftwareUpdateConfiguration
            Software update configuration

		.EXAMPLE
			Disable-SoftwareUpdateConfiguration -AutomationAccountResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}" -ScheduleName "PatchTuesday_xxxx" -SoftwareUpdateConfiguration softwareUpdateConfiguration
	#>
	[CmdletBinding()]
	Param
	(
        [Parameter(Mandatory = $true, Position = 1)]
		[String]$AutomationAccountResourceId,

        [Parameter(Mandatory = $true, Position = 2)]
		[String]$ScheduleName,

        [Parameter(Mandatory = $true, Position = 3)]
		[String]$SoftwareUpdateConfiguration
	)

    try
    {
        $path = ($AutomationSchedulesPath -f $AutomationAccountResourceId, $ScheduleName)
        $softwareUpdateConfigurationName = $ScheduleName.Split("_")
        $response = Invoke-ArmApi-WithPath -Path $path -ApiVersion $AutomationAccountApiVersion -Method $PATCH -Payload $DisableAutomationSchedule
        $disabled = $false

        if ($response.Status -eq $Failed)
        {
            Write-Telemetry -Message ("Failed to Disable schedule {0} for software update configuration {1}." -f $ScheduleName, $softwareUpdateConfigurationName[0]) -Level $ErrorLvl
            return
        }

        Write-Telemetry -Message ("Disabled schedule {0} for software update configuration {1}." -f $ScheduleName, $softwareUpdateConfigurationName[0])
        $disabled = $true
    }
    catch [Exception]
    {
        $exceptionMessage = $_.Exception.Message
        Write-Telemetry -Message ("Failed to Disable schedule {0} for software update configuration {1} with exception {2}." -f $ScheduleName, $softwareUpdateConfigurationName[0], $exceptionMessage) -Level $ErrorLvl
    }
    finally
    {
        $Global:SoftwareUpdateConfigurationsDisabledStatus[$softwareUpdateConfiguration] = $disabled
    }
}

function Disable-AllSoftwareUpdateConfigurations
{
   <#
		.SYNOPSIS
			Disables all software update configurations in the automation account.
	
		.DESCRIPTION
			This command will disable all software update configurations in the automation account.

        .PARAMETER AutomationAccountResourceId
			Automation Account Resource Id.

		.EXAMPLE
			Disable-AllSoftwareUpdateConfigurations -AutomationAccountResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}"
	#>
	[CmdletBinding()]
	Param
	(
        [Parameter(Mandatory = $true, Position = 1)]
		[String]$AutomationAccountResourceId
	)

    try
    {
        Initialize-JobSchedules -AutomationAccountResourceId $AutomationAccountResourceId

        Get-AllSoftwareUpdateConfigurations -AutomationAccountResourceId $AutomationAccountResourceId
     
        $softwareUpdateConfigurations = [System.Collections.ArrayList]@($Global:SoftwareUpdateConfigurationsResourceIDs.Keys)

        foreach ($softwareUpdateConfiguration in $softwareUpdateConfigurations)
        {            
            $schedules = $Global:JobSchedules[$Global:SoftwareUpdateConfigurationsResourceIDs[$softwareUpdateConfiguration]]
            foreach ($schedule in $schedules)
            {
                Disable-SoftwareUpdateConfiguration -AutomationAccountResourceId $AutomationAccountResourceId -ScheduleName $schedule -SoftwareUpdateConfiguration $softwareUpdateConfiguration
            }        
        }
    }
    catch [Exception]
    {
        Write-Telemetry -Message ("Unhandled Exception {0}." -f $_.Exception.Message) -Level $ErrorLvl        
    }
}

function Remove-UpdatesSolutionFromLinkedLogAnalyticsWorkspace
{
   <#
		.SYNOPSIS
			Removes updates solution from linked log analytics workspace.
	
		.DESCRIPTION
			This command will remove updates solution from linked log analytics workspace.

        .PARAMETER AutomationAccountResourceId
			Automation Account Resource Id.

		.EXAMPLE
			Remove-UpdatesSolutionFromLinkedLogAnalyticsWorkspace -AutomationAccountResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}"
	#>
	[CmdletBinding()]
	Param
	(
        [Parameter(Mandatory = $true, Position = 1)]
		[String]$AutomationAccountResourceId
	)

    $response = Invoke-ArmApi-WithPath -Path ($LinkedWorkspacePath -f $AutomationAccountResourceId) -ApiVersion $AutomationApiVersion -Method $GET

    if ($response.Status-eq $Failed)
    {
        Write-Telemetry -Message ("Failed to get linked log analytics workspace for {0}." -f $AutomationAccountResourceId) -Level $ErrorLvl
        throw
    }
    
    $linkedWorkspace = $response.Response.Id
    $parts = $linkedWorkspace.Split("/")
    
    $response = Invoke-ArmApi-WithPath -Path ($SolutionsWithWorkspaceFilterPath -f $parts[2], $parts[4], $parts[8]) -ApiVersion $SolutionsApiVersion -Method $GET
    
    if ($response.Status -eq $Failed)
    {
        Write-Telemetry -Message ("Failed to get solutions for log analytics workspace {0}." -f $linkedWorkspace) -Level $ErrorLvl
        throw
    }
    
    foreach ($solution in $response.Response.value)
    {
        $name = ("Updates(" + $parts[8] + ")")
        if ($solution.name -eq $name )
        {
            $response = Invoke-ArmApi-WithPath -Path $solution.id -ApiVersion $SolutionsApiVersion -Method $DELETE
    
            if ($response.Status -eq $Failed)
            {
                Write-Telemetry -Message ("Failed to remove updates solution from linked log analytics workspace {0} and automation account {1}." -f $linkedWorkspace, $AutomationAccountResourceId) -Level $ErrorLvl
            }
            else
            {
                Write-Telemetry -Message ("Removed updates solution from linked log analytics workspace {0} and automation account {1}." -f $linkedWorkspace, $AutomationAccountResourceId)
                $Global:UpdatesSolutionRemoved = $true               
            }
        }
    }
}

function Get-AllSoftwareUpdateConfigurations
{
    <#
		.SYNOPSIS
			Gets all software update configurations.
	
		.DESCRIPTION
			This function gets all software update configurations with support for pagination.
	
		.PARAMETER AutomationAccountResourceId
			Automation account resource id.
            
		.EXAMPLE
			Get-AllSoftwareUpdateConfigurations -AutomationAccountResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}"
	#>
    [CmdletBinding()]
	Param
	(
		[Parameter(Mandatory = $true, Position = 1)]
		[String]$AutomationAccountResourceId
	)
    $output = $null
    $skip = 0
    do
    {
        $path = ($SoftwareUpdateConfigurationsPath -f $AutomationAccountResourceId, $skip)
        $output = Invoke-ArmApi-WithPath -Path $path -ApiVersion $SoftwareUpdateConfigurationApiVersion -Method $GET
        if($output.Status -eq $Failed)
        {
            Write-Telemetry -Message ("Failed to get software update configurations with error code {0} and error message {1}." -f $output.ErrorCode, $output.ErrorMessage)
            throw
        }
        foreach ($result in $output.Response.value)
        {
            if (!$Global:SoftwareUpdateConfigurationsResourceIDs.ContainsKey($result.id))
            {
                $Global:SoftwareUpdateConfigurationsResourceIDs[$result.id] = $result.name
            }
        }
        # API paginates in multiples of 100.
        $skip = $skip + 100
    }
    while ($null -ne $output.Response.nextLink);
}

# Avoid clogging streams with Import-Modules outputs.
$VerbosePreference = "SilentlyContinue"

$AutomationAccountAzureEnvironment = Get-AutomationVariable -Name "AutomationAccountAzureEnvironment"
if ($null -eq $AutomationAccountAzureEnvironment)
{
    # If AutomationAccountAzureEnvironment variable is not set, default to public cloud.
    $AutomationAccountAzureEnvironment = "AzureCloud"
}

$azConnect = Connect-AzAccount -Identity -AccountId $UserManagedServiceIdentityClientId -SubscriptionId (Parse-ArmId -ResourceId $AutomationAccountResourceId).Subscription -Environment $AutomationAccountAzureEnvironment
if ($null -eq $azConnect)
{
    Write-Telemetry -Message ("Failed to connect with user managed identity. Please ensure that the user managed idenity is added to the automation account and having the required role assignments.") -Level $ErrorLvl
    throw
}
else
{
    Write-Telemetry -Message ("Successfully connected with account {0} to subscription {1}." -f $azConnect.Context.Account, $azConnect.Context.Subscription)
}

try
{
    Disable-AllSoftwareUpdateConfigurations -AutomationAccountResourceId $AutomationAccountResourceId
    Remove-UpdatesSolutionFromLinkedLogAnalyticsWorkspace -AutomationAccountResourceId $AutomationAccountResourceId

    $softwareUpdateConfigurations = [System.Collections.ArrayList]@($Global:SoftwareUpdateConfigurationsResourceIDs.Keys)
    Write-Output ("{0} software update configurations found under automation account {1}." -f $softwareUpdateConfigurations.Count, $AutomationAccountResourceId)
    $countOfDisabledSoftwareUpdateConfigurations = 0

    foreach ($softwareUpdateConfiguration in $softwareUpdateConfigurations)
    {
        if ($Global:SoftwareUpdateConfigurationsDisabledStatus.ContainsKey($softwareUpdateConfiguration) -and $Global:SoftwareUpdateConfigurationsDisabledStatus[$softwareUpdateConfiguration])
        {
            $countOfDisabledSoftwareUpdateConfigurations++
        }
    }

    Write-Output ("{0} software update configurations disabled." -f $countOfDisabledSoftwareUpdateConfigurations)

    if ($Global:UpdatesSolutionRemoved)
    {
        Write-Output ("Updates solution removed from linked log analytics workspace for automation account {0}." -f $AutomationAccountResourceId)
    }
    else
    {
        Write-Output ("Failed to remove updates solution removed from linked log analytics workspace for automation account {0}. Please refer to verbose logs for details." -f $AutomationAccountResourceId)
    }
}
catch [Exception]
{
    Write-Telemetry -Message ("Unhandled Exception {0}." -f $_.Exception.Message) -Level $ErrorLvl
}
