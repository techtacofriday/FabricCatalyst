param
(
    [parameter(Mandatory = $false)] [String] $subscriptionId,
    [parameter(Mandatory = $false)] [String] $resourceGroupName,
    [parameter(Mandatory = $false)] [String] $bicepFilePath = ".\main.bicep"  # Path to your Bicep file
)

# Login to Azure (if not already logged in)deploy
Connect-AzAccount -SubscriptionId $script:subscriptionId | Out-Null

$parameters = @{
    azSubscriptionId = $script:subscriptionId
    azResourceGroupName = $script:resourceGroupName
}

New-AzResourceGroupDeployment `
  -Name "local-bicep-deployment" `
  -ResourceGroupName $script:resourceGroupName `
  -TemplateParameterObject $parameters `
  -TemplateFile $script:bicepFilePath

