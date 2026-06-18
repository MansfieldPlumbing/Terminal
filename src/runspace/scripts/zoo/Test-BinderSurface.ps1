[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Service
)

$result = [pscustomobject]@{
    Service    = $Service
    Accessible = $false
    Descriptor = ""
    Error      = ""
}

try {
    # Resolve ServiceManager via reflection or standard JNI static call
    # Note: ServiceManager might not be directly exposed as public type in some Xamarin bindings,
    # so we load the Java class statically via JNI if needed.
    
    # 1. Obtain IBinder reference
    $binder = [Android.OS.ServiceManager]::GetService($Service)
    
    if ($null -eq $binder) {
        $result.Error = "ServiceManager returned null binder handle. Service does not exist or access is blocked."
        return $result
    }

    # 2. Query basic descriptor details
    $result.Descriptor = $binder.InterfaceDescriptor
    $result.Accessible = $true
} catch {
    # Record the security permission denial or transaction fail message
    $result.Error = $_.Exception.Message
}

$result
