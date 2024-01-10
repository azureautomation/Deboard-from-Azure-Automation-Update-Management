# Deboard-from-Azure-Automation-Update-Management
This Powershell script is designed to remove updates solution from their log analytics workspace linked to the automation account and disables update schedules.

### DESCRIPTION
1. This runbook will disable the schedules associated with the software update configurations to further ensure that the Runbook Patch-MicrosoftOMSComputers is not triggered.
2. It will also remove updates solution from their log analytics workspace linked to the automation account.
3. This will also ensure that system hybrid workers used for Azure Automation Update Management under this automation account stops sending pings and eventually post 30 days they will be deleted automatically.

### PARAMETER AutomationAccountResourceId
        Mandatory. Automation Account Resource Id.

### PARAMETER UserManagedServiceIdentityClientId
        Mandatory. Client Id of the User Assigned Managed Idenitity.

### EXAMPLE
        Deboarding -AutomationAccountResourceId "/subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Automation/automationAccounts/{aaName}"  -ClientId "########-####-####-####-############"

### OUTPUTS
        The count of software update configurations disabled.
        Status of removing updates solution from linked log analytics workspace of the automation account.
