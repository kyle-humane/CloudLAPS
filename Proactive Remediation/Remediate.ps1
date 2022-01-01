<#
.SYNOPSIS
    Proaction Remediation script for CloudLAPS solution used within Endpoint Analytics with Microsoft Endpoint Manager to rotate a local administrator password.

.DESCRIPTION
    This is the remediation script for a Proactive Remediation in Endpoint Analytics used by the CloudLAPS solution.
    
    It will create a new local administrator account if it doesn't already exist on the device and call an Azure Function API defined in the
    script that will generate a new password, update a Secret in a defined Azure Key Vault and respond back with password to be either set or
    updated on the defined local administrator account.

.NOTES
    FileName:    Remediate.ps1
    Author:      Nickolaj Andersen
    Contact:     @NickolajA
    Created:     2020-09-14
    Updated:     2022-01-01

    Version history:
    1.0.0 - (2020-09-14) Script created
    1.0.1 - (2021-10-07) Updated with output for extended details in MEM portal
    1.0.2 - (2022-01-01) Updated virtual machine array with 'Google Compute Engine'
#>
Process {
    # Functions
    function Get-AzureADDeviceID {
        <#
        .SYNOPSIS
            Get the Azure AD device ID from the local device.
        
        .DESCRIPTION
            Get the Azure AD device ID from the local device.
        
        .NOTES
            Author:      Nickolaj Andersen
            Contact:     @NickolajA
            Created:     2021-05-26
            Updated:     2021-05-26
        
            Version history:
            1.0.0 - (2021-05-26) Function created
        #>
        Process {
            # Define Cloud Domain Join information registry path
            $AzureADJoinInfoRegistryKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"

            # Retrieve the child key name that is the thumbprint of the machine certificate containing the device identifier guid
            $AzureADJoinInfoThumbprint = Get-ChildItem -Path $AzureADJoinInfoRegistryKeyPath | Select-Object -ExpandProperty "PSChildName"
            if ($AzureADJoinInfoThumbprint -ne $null) {
                # Retrieve the machine certificate based on thumbprint from registry key
                $AzureADJoinCertificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Thumbprint -eq $AzureADJoinInfoThumbprint }
                if ($AzureADJoinCertificate -ne $null) {
                    # Determine the device identifier from the subject name
                    $AzureADDeviceID = ($AzureADJoinCertificate | Select-Object -ExpandProperty "Subject") -replace "CN=", ""
                    
                    # Write event log entry with DeviceId
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 51 -Message "CloudLAPS: Azure AD device identifier: $($AzureADDeviceID)"

                    # Handle return value
                    return $AzureADDeviceID
                }
            }
        }
    }

    function Get-AzureADRegistrationCertificateThumbprint {
        <#
        .SYNOPSIS
            Get the thumbprint of the certificate used for Azure AD device registration.
        
        .DESCRIPTION
            Get the thumbprint of the certificate used for Azure AD device registration.
        
        .NOTES
            Author:      Nickolaj Andersen
            Contact:     @NickolajA
            Created:     2021-06-03
            Updated:     2021-06-03
        
            Version history:
            1.0.0 - (2021-06-03) Function created
        #>
        Process {
            # Define Cloud Domain Join information registry path
            $AzureADJoinInfoRegistryKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
    
            # Retrieve the child key name that is the thumbprint of the machine certificate containing the device identifier guid
            $AzureADJoinInfoThumbprint = Get-ChildItem -Path $AzureADJoinInfoRegistryKeyPath | Select-Object -ExpandProperty "PSChildName"
    
            # Handle return value
            return $AzureADJoinInfoThumbprint
        }
    }
    
    function New-RSACertificateSignature {
        <#
        .SYNOPSIS
            Creates a new signature based on content passed as parameter input using the private key of a certificate determined by it's thumbprint, to sign the computed hash of the content.
        
        .DESCRIPTION
            Creates a new signature based on content passed as parameter input using the private key of a certificate determined by it's thumbprint, to sign the computed hash of the content.
            The certificate used must be available in the LocalMachine\My certificate store, and must also contain a private key.
    
        .PARAMETER Content
            Specify the content string to be signed.
    
        .PARAMETER Thumbprint
            Specify the thumbprint of the certificate.
        
        .NOTES
            Author:      Nickolaj Andersen / Thomas Kurth
            Contact:     @NickolajA
            Created:     2021-06-03
            Updated:     2021-06-03
        
            Version history:
            1.0.0 - (2021-06-03) Function created
    
            Credits to Thomas Kurth for sharing his original C# code.
        #>
        param(
            [parameter(Mandatory = $true, HelpMessage = "Specify the content string to be signed.")]
            [ValidateNotNullOrEmpty()]
            [string]$Content,
    
            [parameter(Mandatory = $true, HelpMessage = "Specify the thumbprint of the certificate.")]
            [ValidateNotNullOrEmpty()]
            [string]$Thumbprint
        )
        Process {
            # Determine the certificate based on thumbprint input
            $Certificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Thumbprint -eq $CertificateThumbprint }
            if ($Certificate -ne $null) {
                if ($Certificate.HasPrivateKey -eq $true) {
                    # Read the RSA private key
                    $RSAPrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
                    
                    if ($RSAPrivateKey -ne $null) {
                        if ($RSAPrivateKey -is [System.Security.Cryptography.RSACng]) {
                            # Construct a new SHA256Managed object to be used when computing the hash
                            $SHA256Managed = New-Object -TypeName "System.Security.Cryptography.SHA256Managed"
    
                            # Construct new UTF8 unicode encoding object
                            $UnicodeEncoding = [System.Text.UnicodeEncoding]::UTF8
    
                            # Convert content to byte array
                            [byte[]]$EncodedContentData = $UnicodeEncoding.GetBytes($Content)
    
                            # Compute the hash
                            [byte[]]$ComputedHash = $SHA256Managed.ComputeHash($EncodedContentData)
    
                            # Create signed signature with computed hash
                            [byte[]]$SignatureSigned = $RSAPrivateKey.SignHash($ComputedHash, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    
                            # Convert signature to Base64 string
                            $SignatureString = [System.Convert]::ToBase64String($SignatureSigned)
                            
                            # Handle return value
                            return $SignatureString
                        }
                    }
                }
            }
        }
    }
    
    function Get-PublicKeyBytesEncodedString {
        <#
        .SYNOPSIS
            Returns the public key byte array encoded as a Base64 string, of the certificate where the thumbprint passed as parameter input is a match.
        
        .DESCRIPTION
            Returns the public key byte array encoded as a Base64 string, of the certificate where the thumbprint passed as parameter input is a match.
            The certificate used must be available in the LocalMachine\My certificate store.
    
        .PARAMETER Thumbprint
            Specify the thumbprint of the certificate.
        
        .NOTES
            Author:      Nickolaj Andersen / Thomas Kurth
            Contact:     @NickolajA
            Created:     2021-06-07
            Updated:     2021-06-07
        
            Version history:
            1.0.0 - (2021-06-07) Function created
    
            Credits to Thomas Kurth for sharing his original C# code.
        #>
        param(
            [parameter(Mandatory = $true, HelpMessage = "Specify the thumbprint of the certificate.")]
            [ValidateNotNullOrEmpty()]
            [string]$Thumbprint
        )
        Process {
            # Determine the certificate based on thumbprint input
            $Certificate = Get-ChildItem -Path "Cert:\LocalMachine\My" -Recurse | Where-Object { $PSItem.Thumbprint -eq $Thumbprint }
            if ($Certificate -ne $null) {
                # Get the public key bytes
                [byte[]]$PublicKeyBytes = $Certificate.GetPublicKey()
    
                # Handle return value
                return [System.Convert]::ToBase64String($PublicKeyBytes)
            }
        }
    }

    function Get-ComputerSystemType {
        <#
        .SYNOPSIS
            Get the computer system type, either VM or NonVM.
        
        .DESCRIPTION
            Get the computer system type, either VM or NonVM.
        
        .NOTES
            Author:      Nickolaj Andersen
            Contact:     @NickolajA
            Created:     2021-06-07
            Updated:     2022-01-01
        
            Version history:
            1.0.0 - (2021-06-07) Function created
            1.0.1 - (2022-01-01) Updated virtual machine array with 'Google Compute Engine'
        #>
        Process {
            # Check if computer system type is virtual
            $ComputerSystemModel = Get-WmiObject -Class "Win32_ComputerSystem" | Select-Object -ExpandProperty "Model"
            if ($ComputerSystemModel -in @("Virtual Machine", "VMware Virtual Platform", "VirtualBox", "HVM domU", "KVM", "VMWare7,1", "Google Compute Engine")) {
                $ComputerSystemType = "VM"
            }
            else {
                $ComputerSystemType = "NonVM"
            }

            # Handle return value
            return $ComputerSystemType
        }
    }

    # Define the local administrator user name
    $LocalAdministratorName = "<Enter the name of the local administrator account>"

    # Construct the required URI for the Azure Function URL
    $URI = "<Enter Azure Functions URI>"

    # Define event log variables
    $EventLogName = "CloudLAPS-Client"
    $EventLogSource = "CloudLAPS-Client"

    # Intiate logging
    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 10 -Message "CloudLAPS: Local administrator account password rotation started"

    # Retrieve variables required to build request header
    $SerialNumber = Get-WmiObject -Class "Win32_BIOS" | Select-Object -ExpandProperty "SerialNumber"
    $ComputerSystemType = Get-ComputerSystemType
    $AzureADDeviceID = Get-AzureADDeviceID
    $CertificateThumbprint = Get-AzureADRegistrationCertificateThumbprint
    $Signature = New-RSACertificateSignature -Content $AzureADDeviceID -Thumbprint $CertificateThumbprint
    $PublicKeyBytesEncoded = Get-PublicKeyBytesEncodedString -Thumbprint $CertificateThumbprint

    # Construct request header
    $BodyTable = [ordered]@{
        DeviceName = $env:COMPUTERNAME
        DeviceID = $AzureADDeviceID
        SerialNumber = if (-not([string]::IsNullOrEmpty($SerialNumber))) { $SerialNumber } else { $env:COMPUTERNAME } # fall back to computer name if serial number is not present
        Type = $ComputerSystemType
        Signature = $Signature
        Thumbprint = $CertificateThumbprint
        PublicKey = $PublicKeyBytesEncoded
        ContentType = "Local Administrator"
        UserName = $LocalAdministratorName
    }

    # Initiate exit code variable with default value if not errors are caught
    $ExitCode = 0

    # Use TLS 1.2 connection when calling Azure Function
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        # Call Azure Function REST API to store new secret in Key Vault for current computer and have the randomly generated password returned
        Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 11 -Message "CloudLAPS: Calling Azure Function API for password generation and secret update"
        $APIResponse = Invoke-RestMethod -Method "POST" -Uri $URI -Body ($BodyTable | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop

        if ([string]::IsNullOrEmpty($APIResponse)) {
            Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Error -EventId 13 -Message "CloudLAPS: Retrieved an empty response from Azure Function URL"; $ExitCode = 1
        }
        else {
            # Convert password returned from Azure Function API call to secure string
            $SecurePassword = ConvertTo-SecureString -String $APIResponse -AsPlainText -Force

            # Check if existing local administrator user account exists
            $LocalAdministratorAccount = Get-LocalUser -Name $LocalAdministratorName -ErrorAction SilentlyContinue
            if ($LocalAdministratorAccount -eq $null) {
                # Create local administrator account
                try {
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 20 -Message "CloudLAPS: Local administrator account does not exist, attempt to create it"
                    New-LocalUser -Name $LocalAdministratorName -Password $SecurePassword -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword -ErrorAction Stop

                    try {
                        # Add to local built-in security groups: Administrators (S-1-5-32-544)
                        foreach ($Group in @("S-1-5-32-544")) {
                            $GroupName = Get-LocalGroup -SID $Group | Select-Object -ExpandProperty "Name"
                            Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 22 -Message "CloudLAPS: Adding local administrator account to security group '$($GroupName)'"
                            Add-LocalGroupMember -SID $Group -Member $LocalAdministratorName -ErrorAction Stop
                        }
                    }
                    catch [System.Exception] {
                        Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Error -EventId 23 -Message "CloudLAPS: Failed to add '$($LocalAdministratorName)' user account as a member of local '$($GroupName)' group. Error message: $($PSItem.Exception.Message)"; $ExitCode = 1
                    }
                }
                catch [System.Exception] {
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Error -EventId 21 -Message "CloudLAPS: Failed to create new '$($LocalAdministratorName)' local user account. Error message: $($PSItem.Exception.Message)"; $ExitCode = 1
                }
            }
            else {
                # Local administrator account already exists, reset password
                try {
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 30 -Message "CloudLAPS: Local administrator account exists, updating password"
                    Set-LocalUser -Name $LocalAdministratorName -Password $SecurePassword -PasswordNeverExpires $true -UserMayChangePassword $false -ErrorAction Stop
                    
                    # Write output for extended details in MEM portal
                    Write-Output -InputObject "Password rotation completed"
                }
                catch [System.Exception] {
                    Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Error -EventId 31 -Message "CloudLAPS: Failed to rotate password for '$($LocalAdministratorName)' local user account. Error message: $($PSItem.Exception.Message)"; $ExitCode = 1
                }
            }

            # Final event log entry
            Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Information -EventId 40 -Message "CloudLAPS: Local administrator account password rotation completed"
        }
    }
    catch [System.Exception] {
        switch ($PSItem.Exception.Response.StatusCode) {
            "Forbidden" {
                # Write output for extended details in MEM portal
                Write-Output -InputObject "Password rotation not allowed"

                # Write to event log and set exit code
                Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Warning -EventId 14 -Message "CloudLAPS: Forbidden, password was not allowed to be updated"; $ExitCode = 0
            }
            "BadRequest" {
                # Write output for extended details in MEM portal
                Write-Output -InputObject "Password rotation failed"

                # Write to event log and set exit code
                Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Error -EventId 15 -Message "CloudLAPS: BadRequest, failed to update password"; $ExitCode = 1
            }
            default {
                # Write output for extended details in MEM portal
                Write-Output -InputObject "Password rotation failed"

                # Write to event log and set exit code
                Write-EventLog -LogName $EventLogName -Source $EventLogSource -EntryType Error -EventId 12 -Message "CloudLAPS: Call to Azure Function URI failed. Error message: $($PSItem.Exception.Message)"; $ExitCode = 1
            }
        }
    }

    # Handle exit code
    exit $ExitCode
}