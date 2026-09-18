<#
    Installs the latest iyi release into %LOCALAPPDATA%\Programs\iyi:

        irm https://raw.githubusercontent.com/iyilang/iyi/master/install.ps1 | iex

    `install.sh` is this script for Linux and darwin, and the shape is the
    same: resolve the latest release by following GitHub's /releases/latest
    redirect rather than the API, so there is no token and no rate limit in
    the way; check the download against the SHA256SUMS the release publishes
    beside it before anything is unpacked; unpack a relocatable archive into
    a prefix the user owns.

    Knobs, as environment variables because the one-liner above is a pipe and
    cannot be given parameters. Each has a `-Parameter` of the same name for
    when the file is run directly.

      IYI_PREFIX       where to unpack, default %LOCALAPPDATA%\Programs\iyi;
                       the zip is relocatable, so any writable directory works
      IYI_VERSION      a release to pin, e.g. 0.13.0; default is the latest
      IYI_RELEASE_URL  where the release's files are, default the GitHub
                       release. A local directory or a file:// URL also works,
                       which is how CI gates this script against a zip the run
                       just built and before a release exists for it.

    Execution policy: the one-liner is script *text* handed to `iex`, and
    execution policy governs script *files*, so nothing needs changing for
    it. Saved to disk the file is governed, and Windows' default for the user
    scope (RemoteSigned) refuses an unsigned one that carries a download mark
    — so run it as `powershell -ExecutionPolicy Bypass -File install.ps1`.
    Nothing here needs administrator: the prefix is under the user's own
    AppData and the PATH it edits is HKCU's.

    Windows PowerShell 5.1, which is what Windows ships, and PowerShell 7.
    The two disagree about how a redirect reports its destination and about
    whether `Invoke-WebRequest` needs `-UseBasicParsing`, and both are handled
    below.

    What a person still needs after this: the Visual C++ build tools. An iyi
    program is linked by `cl.exe` and the compiler finds it, and the Windows
    SDK's libraries, through the registry — so no developer prompt is needed,
    but the toolset has to be installed. This script says so if it cannot
    find it. A gigabyte of MSVC under a licence this project does not hold is
    not something the zip can carry.
#>
[CmdletBinding()]
param(
    [string] $Prefix = $env:IYI_PREFIX,
    [string] $Version = $env:IYI_VERSION,
    [string] $ReleaseUrl = $env:IYI_RELEASE_URL,

    # Leave the user's PATH alone. The install still works; `iyi` is then the
    # full path to it.
    [switch] $NoPath
)

$ErrorActionPreference = 'Stop'

$Repo = 'iyilang/iyi'

function Say([string] $Line) { Write-Host $Line }

function Die([string] $Line) {
    # A file run has a process of its own and an exit code, which is what the
    # CI step reads, and one clean line on stderr is what a person reads.
    # Through the one-liner there is neither: `iex` runs this text inside the
    # person's session, where `exit` closes their window and takes the
    # message with it, so there the failure is raised and the session stands.
    if ($PSCommandPath) {
        [Console]::Error.WriteLine("install.ps1: $Line")
        exit 1
    }
    throw "install.ps1: $Line"
}

# GitHub refuses anything below TLS 1.2, and Windows PowerShell 5.1 picks its
# protocol from a .NET default that on an un-updated machine is still SSL3 and
# TLS 1.0 — where the download fails with "Could not create SSL/TLS secure
# channel" and nothing about the message says why. PowerShell 7 ignores this
# property and negotiates for itself.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # A .NET too old to name Tls12 cannot reach github.com at all; the
    # download below says so in its own words.
}

# Releases ship one Windows build, x86_64. On an arm64 Windows it runs under
# the system's x64 emulation, together with the x64 MSVC it links through, so
# it is offered rather than refused; 32-bit Windows has no build at all.
$arch = $env:PROCESSOR_ARCHITEW6432
if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
if ($arch -eq 'x86') {
    Die "no release for 32-bit Windows: releases ship windows-x86_64, see README.md (Getting it) to build from source"
}
if ($arch -eq 'ARM64') {
    Say "note: this is an arm64 Windows and the release is x86_64; it runs under the system's x64 emulation"
}

if (-not $Prefix) { $Prefix = Join-Path $env:LOCALAPPDATA 'Programs\iyi' }
$Prefix = [IO.Path]::GetFullPath($Prefix)

# The version, out of the redirect GitHub answers /releases/latest with.
# `-Method Head`, because the page itself is 100 KB of HTML nobody here reads.
if (-not $Version) {
    $latest = "https://github.com/$Repo/releases/latest"
    try {
        $response = Invoke-WebRequest -Uri $latest -Method Head -UseBasicParsing
    } catch {
        Die "could not resolve the latest release of ${Repo}: $($_.Exception.Message)"
    }
    # Where the final URL is reported differs: Windows PowerShell's
    # WebResponse has ResponseUri, PowerShell 7's HttpResponseMessage has the
    # request it ended up making.
    $base = $response.BaseResponse
    $final = if ($base.PSObject.Properties.Name -contains 'ResponseUri') {
        $base.ResponseUri.AbsoluteUri
    } else {
        $base.RequestMessage.RequestUri.AbsoluteUri
    }
    if ($final -notmatch '/tag/v(.+)$') { Die "unexpected redirect for the latest release: $final" }
    $Version = $Matches[1]
}
$Version = $Version -replace '^v', ''

$Asset = "iyi-$Version-windows-x86_64.zip"
if (-not $ReleaseUrl) { $ReleaseUrl = "https://github.com/$Repo/releases/download/v$Version" }

# A local directory or a file:// URL means the files are already on this
# machine: CI points this at the zip the run just built, so the installer is
# gated before a release exists to gate it against. Copied rather than
# fetched, because `Invoke-WebRequest` does not read file:// on both
# PowerShells.
$localBase = $null
if ($ReleaseUrl -match '^file://') {
    $localBase = ([uri] $ReleaseUrl).LocalPath
} elseif ($ReleaseUrl -notmatch '^[a-z][a-z0-9+.-]*://') {
    $localBase = $ReleaseUrl
}

function Fetch([string] $Name, [string] $Destination, [switch] $Optional) {
    if ($localBase) {
        $source = Join-Path $localBase $Name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            if ($Optional) { return $false }
            Die "no such file: $source"
        }
        Copy-Item -LiteralPath $source -Destination $Destination -Force
        return $true
    }

    $uri = "$ReleaseUrl/$Name"
    try {
        Invoke-WebRequest -Uri $uri -OutFile $Destination -UseBasicParsing
    } catch {
        if ($Optional) { return $false }
        Die "download failed: ${uri}: $($_.Exception.Message)"
    }
    return $true
}

$Temp = Join-Path ([IO.Path]::GetTempPath()) ("iyi-install-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Temp | Out-Null

try {
    Say "iyi $Version for windows-x86_64"
    $zip = Join-Path $Temp $Asset
    Fetch $Asset $zip | Out-Null

    # The checksum, and no way past it. `install.sh` carries a note for
    # releases before 0.12.0, which published none; the Windows zip is
    # published from 0.13.0 on and every one of those has a SHA256SUMS, so a
    # missing one here is a broken release rather than an old one, and what
    # comes out of this file reaches a linker.
    $sums = Join-Path $Temp 'SHA256SUMS'
    if (-not (Fetch 'SHA256SUMS' $sums -Optional)) {
        Die "release $Version publishes no SHA256SUMS, and an unverified zip is not unpacked"
    }

    $expected = $null
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
        $fields = $line.Trim() -split '\s+', 2
        if ($fields.Count -eq 2 -and $fields[1].TrimStart('*') -eq $Asset) { $expected = $fields[0].ToLower() }
    }
    if (-not $expected) { Die "the release's SHA256SUMS has no line for $Asset" }

    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
        Die ("$Asset does not match the release's SHA256SUMS: expected $expected, got $actual. " +
             "Nothing was unpacked; try again, and if it repeats, say so at https://github.com/$Repo/issues")
    }
    Say "verified: sha256 $actual"

    # Unpacked here and moved into the prefix afterwards, so a zip that turns
    # out to be short leaves the installed copy alone.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $staging = Join-Path $Temp 'unpacked'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging)

    try {
        New-Item -ItemType Directory -Path $Prefix -Force | Out-Null
        $probe = Join-Path $Prefix ([IO.Path]::GetRandomFileName())
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
    } catch {
        Die "$Prefix is not writable; set IYI_PREFIX to a directory that is"
    }

    # An install over an install. Two things make it more than a copy:
    # Windows refuses to overwrite a running program, and a prelude module
    # deleted upstream would otherwise survive the upgrade and keep answering
    # an `import` out of the old library. So the library is replaced whole and
    # a locked binary is reported as what it is.
    $bin = Join-Path $Prefix 'bin'
    $existing = Join-Path $bin 'iyi.exe'
    if (Test-Path -LiteralPath $existing -PathType Leaf) {
        $installed = (& $existing version 2>$null | Select-Object -First 1)
        Say "replacing what is already at ${Prefix}: $installed"
        foreach ($name in @('iyi.exe', 'LLVM-C.dll')) {
            $path = Join-Path $bin $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                Remove-Item -LiteralPath $path -Force
            } catch {
                Die ("$path is in use, so it cannot be replaced. Close anything running iyi, " +
                     "including a compile in another window, and run this again.")
            }
        }
        $library = Join-Path $Prefix 'share\iyi'
        if (Test-Path -LiteralPath $library) { Remove-Item -LiteralPath $library -Recurse -Force }
    }

    Copy-Item -Path (Join-Path $staging '*') -Destination $Prefix -Recurse -Force

    $iyi = Join-Path $bin 'iyi.exe'
    if (-not (Test-Path -LiteralPath $iyi -PathType Leaf)) { Die "$iyi is not there after unpacking $Asset" }
    $version = & $iyi version
    if ($LASTEXITCODE -ne 0) { Die "$iyi does not start" }
    Say "installed $iyi"
    Say (@($version)[0])
} finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}

$bin = Join-Path $Prefix 'bin'

if (-not $NoPath) {
    # The user's PATH, in the registry rather than through
    # [Environment]::SetEnvironmentVariable: that call writes the value back
    # as a plain string, so a Path holding `%USERPROFILE%\...` — which is how
    # several installers write theirs — comes out expanded, frozen to
    # whatever the profile directory was at this moment. Reading with
    # DoNotExpandEnvironmentNames and writing back the kind it already had
    # leaves every other entry as its owner wrote it.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
    try {
        $current = [string] $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = if ($current) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }

        $entries = @($current -split ';' | Where-Object { $_ } | ForEach-Object { $_.Trim().TrimEnd('\') })
        if ($entries -contains $bin.TrimEnd('\')) {
            Say "PATH already has $bin"
        } else {
            $key.SetValue('Path', (@($current.TrimEnd(';'), $bin) | Where-Object { $_ }) -join ';', $kind)
            Say "added $bin to your PATH"

            # Explorer caches the environment it hands to every program it
            # starts, so without this a new terminal window would not see the
            # change until the next sign-in. `SetEnvironmentVariable` does
            # this broadcast for us and is not usable here for the reason
            # above; where compiling the declaration is not allowed, the
            # sentence below is the fallback.
            try {
                if (-not ('Iyi.Native' -as [type])) {
                    Add-Type -Namespace Iyi -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint msg, System.UIntPtr wParam, string lParam, uint flags, uint timeout, out System.UIntPtr result);
'@
                }
                $answer = [UIntPtr]::Zero
                # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5 s.
                [void] [Iyi.Native]::SendMessageTimeout([IntPtr] 0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref] $answer)
            } catch {
                Say "note: open a new terminal for the PATH change to take effect"
            }
        }
    } finally {
        $key.Dispose()
    }

    # This process's own PATH too, so the line printed at the end can be
    # typed in the window that ran the installer.
    if (($env:PATH -split ';' | ForEach-Object { $_.TrimEnd('\') }) -notcontains $bin.TrimEnd('\')) {
        $env:PATH = "$env:PATH;$bin"
    }
}

# The prerequisite, named rather than discovered the hard way. `vswhere.exe`
# is installed with any Visual Studio or Build Tools since 2017 and is the
# same question the compiler asks the registry when it needs a linker.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$toolset = $null
if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
    $toolset = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
}
if ($toolset) {
    Say "links through the Visual C++ build tools at $(@($toolset)[0])"
} else {
    Say ("note: no Visual C++ build tools found. iyi links a program with cl.exe, so install " +
         "the Visual Studio Build Tools with the workload " +
         "'Desktop development with C++' (https://aka.ms/vs/17/release/vs_BuildTools.exe) " +
         "before building anything.")
}

Say "try: iyi run `"$(Join-Path $Prefix 'share\iyi\samples\hello.iyi')`""
