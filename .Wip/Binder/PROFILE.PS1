$ErrorActionPreference='Stop'

if($global:DBX-and-not$global:DBX[2].IsCompleted){
    [void][Android.Util.Log]::Info('AndroidSMA','BUFFER REUSED')
    return
}

if($global:DBX){
    try{$global:DBX[1].Dispose()}catch{}
    try{$global:DBX[0].Dispose()}catch{}
    $global:DBX=$null
}

$worker={
param($Activity,$Root)

$ErrorActionPreference='Stop'
$BNative=[IntPtr]::Zero
$USB=$null

$a=[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
    [Reflection.AssemblyName]::new('AndroidSMA.DB.'+[Guid]::NewGuid().ToString('N')),
    [Reflection.Emit.AssemblyBuilderAccess]::Run
)
$m=$a.DefineDynamicModule('DB')
$t=$m.DefineType('DBN',[Reflection.TypeAttributes]'Public,Abstract,Sealed')
$f=[Reflection.MethodAttributes]'Public,Static,PinvokeImpl'
$c=[Runtime.InteropServices.CallingConvention]::Cdecl

$x=$t.DefinePInvokeMethod(
    'AServiceManager_getService','libbinder_ndk.so','AServiceManager_getService',
    $f,[Reflection.CallingConventions]::Standard,[IntPtr],
    [Type[]]@([string]),$c,[Runtime.InteropServices.CharSet]::Ansi
)
$x.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

$x=$t.DefinePInvokeMethod(
    'AIBinder_ping','libbinder_ndk.so','AIBinder_ping',
    $f,[Reflection.CallingConventions]::Standard,[int],
    [Type[]]@([IntPtr]),$c,[Runtime.InteropServices.CharSet]::None
)
$x.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

$x=$t.DefinePInvokeMethod(
    'AIBinder_toJavaBinder','libbinder_ndk.so','AIBinder_toJavaBinder',
    $f,[Reflection.CallingConventions]::Standard,[IntPtr],
    [Type[]]@([IntPtr],[IntPtr]),$c,[Runtime.InteropServices.CharSet]::None
)
$x.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

$x=$t.DefinePInvokeMethod(
    'AIBinder_decStrong','libbinder_ndk.so','AIBinder_decStrong',
    $f,[Reflection.CallingConventions]::Standard,[void],
    [Type[]]@([IntPtr]),$c,[Runtime.InteropServices.CharSet]::None
)
$x.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)

$N=$t.CreateType()

$l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Any,45888)

try{
    $l.Start()
    [void][Android.Util.Log]::Info(
        'AndroidSMA',
        "BUFFER READY 0.0.0.0:45888 PID=$([Environment]::ProcessId)"
    )

    try{
        $BNative=$N::AServiceManager_getService('usb')

        if($BNative-ne[IntPtr]::Zero){
            $j=$N::AIBinder_toJavaBinder(
                [Android.Runtime.JNIEnv]::Handle,
                $BNative
            )

            $g=$null
            foreach($q in [Java.Lang.Object].GetMethods(
                [Reflection.BindingFlags]'Public,Static'
            )){
                if(
                    $q.Name-eq'GetObject'-and
                    $q.IsGenericMethodDefinition-and
                    $q.GetParameters().Length-eq2
                ){
                    $g=$q
                    break
                }
            }

            if($g-and$j-ne[IntPtr]::Zero){
                $USB=$g.MakeGenericMethod(
                    [Android.OS.IBinder]
                ).Invoke(
                    $null,
                    [object[]]@(
                        $j,
                        [Android.Runtime.JniHandleOwnership]::DoNotTransfer
                    )
                )
            }
        }

        if($USB){
            [void][Android.Util.Log]::Info(
                'AndroidSMA',
                "BINDER READY $($USB.InterfaceDescriptor)"
            )
        }else{
            [void][Android.Util.Log]::Warn(
                'AndroidSMA',
                'BINDER UNAVAILABLE; BUFFER REMAINS LIVE'
            )
        }
    }catch{
        [void][Android.Util.Log]::Error(
            'AndroidSMA',
            "BINDER INIT $($_.Exception.Message)"
        )
    }

    while($true){
        $client=$l.AcceptTcpClient()
        $reader=$null
        $writer=$null

        try{
            $stream=$client.GetStream()
            $reader=[IO.StreamReader]::new(
                $stream,[Text.UTF8Encoding]::new($false),$false,4096,$true
            )
            $writer=[IO.StreamWriter]::new(
                $stream,[Text.UTF8Encoding]::new($false),4096,$true
            )
            $writer.AutoFlush=$true
            $writer.WriteLine("READY $([Environment]::ProcessId)")

            while($true){
                $line=$reader.ReadLine()
                if($null-eq$line){break}

                try{
                    if($line.Length-gt1398104){throw 'COMMAND_TOO_LARGE'}

                    $bytes=[Convert]::FromBase64String($line)
                    if($bytes.Length-gt1048576){throw 'COMMAND_TOO_LARGE'}

                    $code=[Text.Encoding]::UTF8.GetString($bytes)
                    $result=@(. ([scriptblock]::Create($code)) 2>&1)

                    $writer.WriteLine("OK $($result.Count)")

                    foreach($value in $result){
                        $text=if($null-eq$value){'NULL'}else{[string]$value}
                        $data=[Convert]::ToBase64String(
                            [Text.Encoding]::UTF8.GetBytes($text)
                        )
                        $writer.WriteLine("DATA $data")
                    }
                }catch{
                    $text="$($_.Exception.GetType().FullName): $($_.Exception.Message)"
                    $data=[Convert]::ToBase64String(
                        [Text.Encoding]::UTF8.GetBytes($text)
                    )
                    $writer.WriteLine("ERR $data")
                }

                $writer.WriteLine('END')
            }
        }catch{
            [void][Android.Util.Log]::Error(
                'AndroidSMA',
                "CLIENT $($_.Exception.Message)"
            )
        }finally{
            try{$reader.Dispose()}catch{}
            try{$writer.Dispose()}catch{}
            try{$client.Dispose()}catch{}
        }
    }
}finally{
    try{$l.Stop()}catch{}
    if($BNative-ne[IntPtr]::Zero){
        try{$N::AIBinder_decStrong($BNative)}catch{}
    }
}
}

$initial=[System.Management.Automation.Runspaces.InitialSessionState]::Create()
$initial.LanguageMode=[System.Management.Automation.PSLanguageMode]::FullLanguage
$initial.ThreadOptions=[System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread

$rs=[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initial)
$rs.Open()

$ps=[System.Management.Automation.PowerShell]::Create()
$ps.Runspace=$rs

[void]$ps.AddScript($worker.ToString()).AddArgument($Activity).AddArgument($PSScriptRoot)
$async=$ps.BeginInvoke()

$global:DBX=@($rs,$ps,$async)

[void][Android.Util.Log]::Info('AndroidSMA','COMMAND BUFFER ARMED')