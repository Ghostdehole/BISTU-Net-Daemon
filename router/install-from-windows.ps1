$ErrorActionPreference = 'Stop'

try {
    $installer = Join-Path $PSScriptRoot 'bistu-auth-router-1.8.0.sh'
    if (-not [IO.File]::Exists($installer)) {
        throw '请先完整解压 ZIP，然后从同一目录双击 install-from-windows.cmd。'
    }
    $systemDir = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Join-Path $env:SystemRoot 'Sysnative'
    } else {
        [Environment]::SystemDirectory
    }
    $ssh = Join-Path $systemDir 'OpenSSH\ssh.exe'
    if (-not [IO.File]::Exists($ssh)) {
        throw '请在 Windows 的“可选功能”中安装 OpenSSH 客户端，再重新运行。'
    }

    $address = Read-Host '路由器 LAN IPv4 地址（回车使用 192.168.8.1）'
    if ($address -eq '') { $address = '192.168.8.1' }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($address, [ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ip.ToString() -cne $address -or
        $ip.GetAddressBytes()[0] -eq 0 -or $ip.GetAddressBytes()[0] -ge 224) {
        throw '请输入四段十进制单播 IPv4 地址，例如 192.168.8.1。'
    }
    $target = 'root@' + $ip.ToString()
    Write-Host '首次连接时请核对 SSH 主机指纹。上传和安装分两次登录，可能会两次提示输入路由器管理员密码。'

    # Keep the upload byte-for-byte intact and leave the SSH password prompt on the console.
    $source = [IO.File]::OpenRead($installer)
    $process = New-Object Diagnostics.Process
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = [BitConverter]::ToString($sha.ComputeHash($source)).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        $source.Position = 0

        # A five-minute lease cleans up an upload if the second SSH connection never arrives.
        # Removing "pending" atomically gives either the interactive session or the timer ownership.
        $upload = @'
umask 077; d=$(mktemp -d /tmp/bistu-win.XXXXXXXX) || exit 1;
trap 'rm -f $d/installer.sh; rmdir $d/pending 2>/dev/null; rmdir $d' 0;
trap 'exit 1' HUP INT TERM;
cd $d && cat >installer.sh && printf '%s  installer.sh\n' @HASH@ | sha256sum -c - >&2 && mkdir pending || exit 1;
(trap '' HUP; n=0; while [ -d $d/pending ] && [ $n -lt 60 ]; do sleep 5; n=$((n+1)); done;
if rmdir $d/pending 2>/dev/null; then rm -f $d/installer.sh; rmdir $d; fi) </dev/null >/dev/null 2>&1 &
printf '%s\n' $d && trap - 0
'@
        $upload = ($upload -replace '\r?\n', ' ').Replace('@HASH@', $digest)
        $process.StartInfo.FileName = $ssh
        $process.StartInfo.Arguments = "-T -o StrictHostKeyChecking=ask -o ConnectTimeout=12 $target `"$upload`""
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        [void]$process.Start()
        $output = $process.StandardOutput.ReadLineAsync()
        $inputStream = $process.StandardInput.BaseStream
        try { $source.CopyTo($inputStream) } finally { $inputStream.Close() }
        $process.WaitForExit()
        $remoteDir = $output.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $remoteDir -cnotmatch '\A/tmp/bistu-win\.[A-Za-z0-9]{8}\z') {
            throw '上传或 SHA-256 校验失败，安装已停止。'
        }
    } finally {
        $source.Dispose()
        $process.Dispose()
    }

    # The path is validated above before it is passed to the router shell.
    $run = @'
d=@DIR@; rmdir $d/pending || exit 1; trap 'rm -f $d/installer.sh; rmdir $d' 0;
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; sh $d/installer.sh
'@
    $run = ($run -replace '\r?\n', ' ').Replace('@DIR@', $remoteDir)
    & $ssh -tt -o StrictHostKeyChecking=ask -o ConnectTimeout=12 $target $run
    $status = $LASTEXITCODE
    if ($status -ne 0) {
        [Console]::Error.WriteLine("安装或 SSH 连接退出，状态码 $status。")
    }
    exit $status
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
