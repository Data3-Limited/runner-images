param(
    [Parameter (Mandatory)] [UInt32] $BuildId,
    [Parameter (Mandatory)] [string] $Organization,
    [Parameter (Mandatory)] [string] $Project,
    [Parameter (Mandatory)] [string] $ImageType,
    [Parameter (Mandatory)] [string] $ManagedImageName,
    [Parameter (Mandatory)] [string] $DefinitionId,
    [Parameter (Mandatory)] [string] $AccessToken
)

$Body = @{
    resources = @{
      repositories = @{
        self = @{
          refName = "refs/heads/main"
        }
      }
    }
    templateParameters = @{
      managed_image_name = $ManagedImageName
    }
} | ConvertTo-Json -Depth 3

$URL = "https://dev.azure.com/{0}/{1}/_apis/pipelines/{2}/runs?api-version=7.1-preview.1" -f $Organization, $Project, $DefinitionId
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("'':${AccessToken}"))
$headers = @{
    Authorization = "Basic ${base64AuthInfo}"
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$NewRelease = Invoke-RestMethod $URL -Body $Body -Method "POST" -Headers $headers -ContentType "application/json"

Write-Host "Created release: $($NewRelease._links.web.href)"
