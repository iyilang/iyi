param(
    [Parameter(Position = 0, ValueFromRemainingArguments)] [string[]] $IyiArgs
)

# iyi, run out of this checkout: `.\bin\iyi.ps1 run samples\iyi\hello.iyi`.
#
# `bin\crystal.ps1` next to this file is the wrapper Crystal ships, and it has
# work to do: find a parent compiler to bootstrap from, set `CRYSTAL_PATH` to
# this checkout, ask the installed compiler where its libraries are, and say
# which binary it ended up using. None of that applies here. `.build\iyi.exe`
# is built with its prelude's location baked in relative to itself
# (`IYI_CONFIG_PATH` in Makefile.win), which is the same thing that makes the
# zip relocatable, so this script only has to find the binary and get out of
# the way. `bin\iyi` is this script in POSIX sh and `bin\iyi.bat` is it in
# cmd, and all three owe the same nothing.

$Root = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSCommandPath) '..'))
$Binary = Join-Path $Root '.build\iyi.exe'

if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) {
    [Console]::Error.WriteLine("iyi is not built yet. Run ``make -f Makefile.win iyi`` in $Root.")
    exit 1
}

& $Binary @IyiArgs

# The compiler's own exit code, because that is what a caller reads: `iyi
# check` and `iyi test` are run for their status, and a wrapper that returns
# its own turns a failing build into a passing script.
exit $LASTEXITCODE
