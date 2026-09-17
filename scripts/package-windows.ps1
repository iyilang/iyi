<#
    The gate that makes the Windows zip trustworthy: it unpacks the zip
    somewhere that is not this checkout and builds and runs a program out of
    it with PATH cut down to Windows' own four directories.

        powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package-windows.ps1

    What it proves

      * The zip is relocatable. The binary finds its prelude through
        `$ORIGIN\..\share\iyi\src` baked in at build time (Makefile.win,
        `IYI_CONFIG_PATH`), so a `bin\iyi.exe` beside a `share\iyi` works
        wherever it lands. Nothing here sets IYI_PATH or CRYSTAL_PATH, and
        both are removed from the environment first: the compiler falls back
        to `CRYSTAL_PATH`, so a stray one would answer for the zip and this
        would stop proving anything about the zip.
      * The zip carries what its own binary loads. `dumpbin /dependents`
        names LLVM-C.dll and VCRUNTIME140.dll; the first is in `bin` beside
        the binary, where the loader reads before it reads PATH, and with
        PATH trimmed there is no LLVM anywhere on it to hide a missing copy.
      * The library a program opts into shipped. 0.11.0 shipped no `src/std`
        at all and answered `import std/text` with "can't find module" for
        everybody who downloaded it, and a hello-world passed that release.
      * The binary in the zip is an optimised one. `check_iyi_is_release`
        asks that of `.build` at package time; this asks it of the file that
        ships.

    What it does not prove

      * That the Visual C++ build tools are optional. They are not, and this
        gate runs on a machine that has them installed — what the trimmed
        PATH proves is that no *developer prompt*, no directory on PATH and
        no LLVM install are needed, not that the toolset can be absent.
        Measured, not assumed: an iyi program links through `cl.exe`
        (`src/compiler/iyi/compiler.cr`, MSVC_LINKER), and the compiler finds
        it by absolute path out of the registry together with the Windows
        SDK's `/LIBPATH`s (`Crystal::System::VisualStudio.find_latest_msvc_path`,
        `WindowsSDK.find_win10_sdk_libpath`) rather than off PATH. That is why
        the trimmed PATH below does not stop a build, and it is also why it
        says nothing about a machine where the toolset was never installed.
        The zip carries no linker and is not going to: MSVC is a
        gigabyte-scale download under a licence this project does not hold.
        So the build tools are a prerequisite and `install.ps1` says so and
        checks for them.
      * `--crystal`. The zip carries iyi's own prelude and `std` and neither
        Crystal's library nor the import libraries its prelude links, so a
        program built with `--crystal` out of this zip stops in the linker.
      * Anything about `iyi daemon`. The zip carries no `iyi-daemon.exe`:
        `make -f Makefile.win iyi-daemon` stops at `can't find file 'c/poll'`
        from `src/compiler/iyi/command/daemon.cr:4`, and the design behind
        that line is the rest of it — the server loop is `poll(2)` and the
        per-build worker is `fork` — so there is no Windows binary to
        package.
      * That the binary starts where the Visual C++ runtime is absent. It
        comes with the build tools above, and Windows' own directories carry
        a copy, so the case does not arise on a machine that can link.
#>
[CmdletBinding()]
param(
    # The zip to judge. Default: the newest one `make -f Makefile.win
    # iyi-zip` left in `.build`, or in `O` if it was pointed elsewhere.
    [string] $Zip,

    # Where to unpack it. Default: a fresh directory under TEMP, removed on
    # the way out. It must not be inside this checkout, which is the whole
    # point of the gate, so the default is not `.build`.
    [string] $WorkDir,

    # Keep the unpacked tree for a look afterwards.
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Say([string] $Line) { Write-Host $Line }

function Die([string] $Line) {
    [Console]::Error.WriteLine("package-windows.ps1: $Line")
    exit 1
}

$RepoRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSCommandPath) '..'))

if (-not $Zip) {
    # `.build` and one level under it: `make -f Makefile.win iyi-zip
    # O=.build\pkg` is how the zip gets built without disturbing the
    # `.build\iyi.exe` somebody else is measuring, and its zip lands there.
    # A `-Path .build\* -Filter` instead does not descend at all, which is
    # how this first picked a zip from three days earlier.
    $build = Join-Path $RepoRoot '.build'
    $roots = @($build) + @(Get-ChildItem -LiteralPath $build -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    $candidates = @($roots |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'iyi-*-windows-x86_64.zip' -File -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        Die "no iyi-*-windows-x86_64.zip under $build; run ``make -f Makefile.win iyi-zip release=1`` first, or pass -Zip"
    }
    $Zip = $candidates[0].FullName
}

if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { Die "no such zip: $Zip" }
$Zip = (Resolve-Path -LiteralPath $Zip).Path
$ZipName = [IO.Path]::GetFileName($Zip)

Say "zip: $Zip"
Say ("size: {0:N0} bytes" -f (Get-Item -LiteralPath $Zip).Length)

# The line `install.ps1` will check the download against, checked here
# against the file it describes. A SHA256SUMS that does not match its own zip
# turns every install into the loud refusal the installer keeps for a
# tampered download.
$sums = Join-Path (Split-Path -Parent $Zip) 'SHA256SUMS'
if (Test-Path -LiteralPath $sums -PathType Leaf) {
    $expected = $null
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
        $fields = $line.Trim() -split '\s+', 2
        if ($fields.Count -eq 2 -and $fields[1].TrimStart('*') -eq $ZipName) { $expected = $fields[0].ToLower() }
    }
    if (-not $expected) { Die "$sums has no line for $ZipName" }
    $actual = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) { Die "$ZipName does not match ${sums}: expected $expected, got $actual" }
    Say "sha256: $actual, and SHA256SUMS says the same"
} else {
    Die "no SHA256SUMS beside the zip; ``make -f Makefile.win iyi-zip`` writes one and install.ps1 reads it"
}

if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ("iyi-package-gate-" + [IO.Path]::GetRandomFileName()) }
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if ($WorkDir.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Die "-WorkDir $WorkDir is inside the checkout, where a program can reach this tree's src; pick one that is not"
}
if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Path $WorkDir | Out-Null

$unpacked = Join-Path $WorkDir 'iyi'
$scratch = Join-Path $WorkDir 'build'
New-Item -ItemType Directory -Path $scratch | Out-Null

try {
    # `ZipFile` rather than `Expand-Archive`: the same call the makefile
    # writes the zip with, and on PowerShell 5.1 it is seconds where
    # Expand-Archive is minutes over 85 MB of LLVM.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Zip, $unpacked)
    Say "unpacked into $unpacked"

    # The structural half, before anything is run: a zip missing one of these
    # names is a zip whose failure below would be reported as whatever the
    # compiler says about a file it cannot find.
    $required = @(
        'bin\iyi.exe',
        'bin\LLVM-C.dll',
        'share\iyi\src\iyi\prelude.iyi',
        'share\iyi\src\std\text.iyi',
        'share\iyi\samples\hello.iyi',
        'share\iyi\samples\std_text.iyi',
        'share\iyi\README.md',
        'share\iyi\SPEC.md',
        'share\licenses\iyi\LICENSE',
        'share\licenses\iyi\NOTICE.md'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $unpacked $_)) })
    if ($missing.Count -gt 0) { Die "the zip does not carry: $($missing -join ', ')" }
    Say "layout: $($required.Count) required paths, all present"

    $iyi = Join-Path $unpacked 'bin\iyi.exe'

    # Windows' own directories and nothing else: no LLVM, no Visual Studio,
    # no Crystal, no toolchain a developer put there. Built out of
    # SystemRoot rather than pasted, because a runner's Windows is not
    # always on C:.
    $trimmed = @(
        (Join-Path $env:SystemRoot 'system32'),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32\Wbem'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    ) -join ';'

    # Saved and restored rather than set in a child: the run has to see this
    # environment and nothing of the one that built the zip, and a child
    # process inherits whatever is not overridden.
    $saved = @{}
    $cut = @('PATH', 'IYI_PATH', 'CRYSTAL_PATH', 'CRYSTAL_LIBRARY_PATH', 'CRYSTAL_OPTS', 'CC', 'INCLUDE', 'LIB', 'LIBPATH')
    foreach ($name in $cut) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }

    try {
        # `Remove-Item Env:\...`, and the difference is the whole of this
        # gate: `[Environment]::SetEnvironmentVariable($name, $null)` removes
        # the variable under Windows PowerShell 5.1 and leaves it *set and
        # empty* under PowerShell 7 (measured on 5.1.26100 and 7.6.6), where
        # `iyi` reads an empty IYI_PATH as "search nothing" and answers
        # `can't find file 'iyi/prelude'` with the zip's own prelude sitting
        # beside it. That is how this step first failed on the runner, which
        # uses pwsh, while passing here under 5.1. The provider's Remove
        # takes the variable out on both hosts, and it is asked afterwards
        # rather than assumed: the whole claim of the gate is what the
        # compiler cannot see.
        foreach ($name in $cut) {
            if (Test-Path -LiteralPath "Env:\$name") { Remove-Item -LiteralPath "Env:\$name" }
        }
        $stillSet = @($cut | Where-Object { Test-Path -LiteralPath "Env:\$_" })
        if ($stillSet.Count -gt 0) {
            Die "these are still in the environment and the run would not prove the zip: $($stillSet -join ', ')"
        }
        [Environment]::SetEnvironmentVariable('PATH', $trimmed)
        Say "PATH: $trimmed"
        Say "removed from the environment: $((@($cut) | Where-Object { $_ -ne 'PATH' }) -join ', ')"

        # A directory that is not the checkout and not the unpacked tree: a
        # relative `import` or a leaked `lib` on the search path would
        # resolve out of the current directory, and a person building in
        # their own project is not standing in either place.
        Push-Location $scratch
        try {
            $version = & $iyi --version
            if ($LASTEXITCODE -ne 0) { Die "$iyi does not start: $($version -join ' ')" }
            if (($version -join "`n") -match 'not built in release mode') {
                Die "the iyi.exe in the zip is not an optimised build; ``make -f Makefile.win iyi-zip release=1`` is what builds one"
            }
            Say "iyi.exe: $(@($version)[0])"

            # What a person who downloads it does. The text is the sample's
            # own output: `share\iyi\samples\hello.iyi` prints these six
            # lines, and if the sample changes this list changes with it —
            # an exit code alone would pass a program that compiled and
            # printed nothing.
            $expectedHello = @(
                'Hello, iyi!',
                'HELLO, IYI!',
                'BEEP 42',
                'Hello, crystal!',
                'BEEP 7',
                '-> BEEP 9'
            )
            $hello = Join-Path $unpacked 'share\iyi\samples\hello.iyi'
            $printed = @(& $iyi run $hello)
            if ($LASTEXITCODE -ne 0) { Die "``iyi run hello.iyi`` out of the zip failed with $LASTEXITCODE" }
            if (($printed -join "`n") -ne ($expectedHello -join "`n")) {
                Say "expected:"
                $expectedHello | ForEach-Object { Say "  $_" }
                Say "printed:"
                $printed | ForEach-Object { Say "  $_" }
                Die "hello.iyi out of the zip did not print what it prints in the checkout"
            }
            Say "hello.iyi: built and ran, $($printed.Count) lines, all as expected"

            # And the library beside the prelude, which is a separate claim:
            # `import std/text` is resolved out of `share\iyi\src\std`.
            $stdText = Join-Path $unpacked 'share\iyi\samples\std_text.iyi'
            $stdOut = @(& $iyi run $stdText)
            if ($LASTEXITCODE -ne 0) { Die "``iyi run std_text.iyi`` out of the zip failed with $LASTEXITCODE" }
            if ($stdOut.Count -eq 0) { Die "std_text.iyi out of the zip printed nothing" }
            Say "std_text.iyi: built and ran, $($stdOut.Count) lines out of share\iyi\src\std"

            # `iyi build` writes a binary a person then runs, and where it
            # lands matters: the program is linked in the current directory,
            # not beside the compiler.
            $built = Join-Path $scratch 'hello.exe'
            & $iyi build -o $built $hello
            if ($LASTEXITCODE -ne 0) { Die "``iyi build`` out of the zip failed with $LASTEXITCODE" }
            if (-not (Test-Path -LiteralPath $built)) { Die "``iyi build -o $built`` wrote no program" }
            $ranBuilt = @(& $built)
            if ($LASTEXITCODE -ne 0) { Die "the program ``iyi build`` wrote failed with $LASTEXITCODE" }
            if (($ranBuilt -join "`n") -ne ($expectedHello -join "`n")) {
                Die "the built program printed something else: $($ranBuilt -join ' | ')"
            }
            Say "iyi build: wrote $built and it prints the same six lines"
        } finally {
            Pop-Location
        }
    } finally {
        # The same asymmetry on the way back: a variable that was not set
        # stays not set, rather than coming back empty for whatever runs
        # after this script in the same session.
        foreach ($name in $cut) {
            if ($null -eq $saved[$name]) {
                if (Test-Path -LiteralPath "Env:\$name") { Remove-Item -LiteralPath "Env:\$name" }
            } else {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }

    Say "the zip is good: $ZipName"
} finally {
    if ($Keep) {
        Say "kept $WorkDir"
    } elseif (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
