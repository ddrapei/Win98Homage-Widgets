<#
  Live tests for the sticky note: NoteEdit.dll and Skin.lua together, in the
  Rainmeter that is running.  cargo test covers the plugin's file handling on
  its own; this covers what only the two together can get wrong -- the Open
  and Close handshake, the checkbox rules around it, where the box opens
  scrolled to, and characters on their way through.

  There is no Lua interpreter to test Skin.lua by itself, so it is driven the
  way Rainmeter drives it: the skin's own functions are called with
  !CommandMeasure, and the box is typed into and dismissed with window
  messages -- the same WM_CHAR, WM_KEYDOWN and WM_ACTIVATE a keyboard and a
  click elsewhere would send.

  The note is restored afterwards, byte for byte, whatever happens.

    pwsh -File tests\live.ps1        (the skin must be loaded)
#>

$ErrorActionPreference = 'Stop'
$Rainmeter = 'C:\Program Files\Rainmeter\Rainmeter.exe'
$Config    = 'Win98StickyNotes'
$Folder    = Split-Path (Split-Path $PSScriptRoot)
$Note      = Join-Path $Folder 'Notes.txt'
$Bak       = "$Note.bak"

Add-Type -Namespace Live -Name User32 -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr w);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr w, uint m, IntPtr wp, System.Text.StringBuilder lp);
[DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr w, uint m, IntPtr wp, IntPtr lp);
'@
$U = [Live.User32]

# ---- driving the skin ---------------------------------------------------------

function Skin([string]$lua) {
    & $Rainmeter '!CommandMeasure' 'MeasureSkin' $lua $Config
    Start-Sleep -Milliseconds 350
}
function OpenSheet  { Skin 'Click(60,20)' }         # a click on the text column
function ClickBox1  { Skin 'Click(5,5)' }           # a click on row 1's checkbox

function Box  { $U::FindWindowW('Win98NoteEdit', $null) }
function Edit { $U::FindWindowExW((Box), [IntPtr]::Zero, 'Edit', $null) }
function IsOpen { $b = Box; ($b -ne [IntPtr]::Zero) -and $U::IsWindowVisible($b) }

function BoxText {
    $e = Edit
    $n = [int]$U::SendMessageW($e, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero)      # WM_GETTEXTLENGTH
    $sb = [System.Text.StringBuilder]::new($n + 1)
    [void]$U::SendMessageW($e, 0x000D, [IntPtr]($n + 1), $sb)                    # WM_GETTEXT
    $sb.ToString()
}
function FirstVisibleLine { [int]$U::SendMessageW((Edit), 0x00CE, [IntPtr]::Zero, [IntPtr]::Zero) }

# Typed a character at a time, with | standing for Enter.
function Keys([string]$text) {
    $e = Edit
    foreach ($c in $text.ToCharArray()) {
        $code = if ($c -eq '|') { 13 } else { [int]$c }
        [void]$U::SendMessageW($e, 0x0102, [IntPtr]$code, [IntPtr]::Zero)          # WM_CHAR
    }
}
function Escape {
    [void]$U::SendMessageW((Edit), 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)         # WM_KEYDOWN
    Start-Sleep -Milliseconds 350
}
# What a click anywhere else delivers to the box.
function ClickElsewhere {
    [void]$U::SendMessageW((Box), 0x0006, [IntPtr]::Zero, [IntPtr]::Zero)        # WM_ACTIVATE, inactive
    Start-Sleep -Milliseconds 350
}

# The comma keeps an empty file an empty array: PowerShell unrolls an array
# returned from a function, and an empty one would come out as $null -- "no
# file" -- and be restored by deleting it.
function Bytes([string]$path) { if (Test-Path $path) { ,[IO.File]::ReadAllBytes($path) } else { $null } }
function Text([string]$path)  { if (Test-Path $path) { [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)) } else { $null } }
function Seed([byte[]]$bytes) { [IO.File]::WriteAllBytes($Note, $bytes); Start-Sleep -Milliseconds 2200 }   # past a skin tick
function SeedText([string]$s) { Seed ([Text.UTF8Encoding]::new($false).GetBytes($s)) }

# ---- reporting ------------------------------------------------------------------

$script:failed = 0
function Check([bool]$ok, [string]$what, $detail = '') {
    if ($ok) { Write-Host "  ok    $what" }
    else     { Write-Host "  FAIL  $what  $detail" -ForegroundColor Red; $script:failed++ }
}
function Section([string]$name) {
    if (IsOpen) { ClickElsewhere }          # every test starts from a closed box
    Write-Host "`n$name"
}

# The box opens with the caret at the end of the note -- the pointer is not
# over it when a test clicks -- and a note ends in a line break, so typing
# goes on a line of its own.

# ---- the tests --------------------------------------------------------------------

if (-not (Get-Process Rainmeter -ErrorAction SilentlyContinue)) { throw 'Rainmeter is not running' }
$savedNote, $savedBak = (Bytes $Note), (Bytes $Bak)

try {
    Section 'Typing saves as it goes, and a click elsewhere saves and closes'
    SeedText "[ ] milk`n"
    OpenSheet
    Check (IsOpen) 'a click on the text opens the box'
    Check ((BoxText) -eq "[ ] milk`r`n") 'the box holds the file' (BoxText)
    Keys 'bread'
    Start-Sleep -Milliseconds 1500
    Check ((Text $Note) -eq "[ ] milk`nbread`n") 'a pause writes the typing (AutoSave)' (Text $Note)
    Keys '|jam'
    ClickElsewhere
    Check (-not (IsOpen)) 'a click elsewhere closes the box'
    Check ((Text $Note) -eq "[ ] milk`nbread`njam`n") 'and saves what the pause had not' (Text $Note)
    Check ((Text $Bak) -eq "[ ] milk`n") 'the .bak is the note from before the edit, not an autosave' (Text $Bak)

    Section 'The checkbox after a close'
    ClickBox1
    Check ((Text $Note) -eq "[x] milk`nbread`njam`n") 'a tick lands, so the skin heard Closed() and re-read the note' (Text $Note)

    Section 'The skin knows the box is open'
    OpenSheet
    Check (IsOpen) 'opened'
    OpenSheet
    Check (-not (IsOpen)) 'a second click on the skin finishes the edit instead of acting on it'
    Check ((Text $Note) -eq "[x] milk`nbread`njam`n") 'and changes nothing' (Text $Note)

    Section 'Escape saves and closes'
    OpenSheet
    Keys 'eggs'
    Escape
    Check (-not (IsOpen)) 'Escape closes the box'
    Check ((Text $Note) -eq "[x] milk`nbread`njam`neggs`n") 'and saves' (Text $Note)

    Section 'A refresh with the box open saves first'
    OpenSheet
    Keys 'tea'
    & $Rainmeter '!Refresh' $Config; Start-Sleep -Milliseconds 1200
    Check ((Text $Note) -eq "[x] milk`nbread`njam`neggs`ntea`n") 'the typing is in the file' (Text $Note)

    Section 'A write that fails keeps the typing, and holds the checkboxes back'
    SeedText "[ ] milk`n"
    OpenSheet
    Set-ItemProperty $Note IsReadOnly $true
    try {
        Keys 'X'
        ClickElsewhere
        Check ((Text $Note) -eq "[ ] milk`n") 'the refused write left the note alone' (Text $Note)
        Check (-not (Test-Path "$Note.tmp")) 'and left no temporary file'
        ClickBox1
        Check ((Text $Note) -eq "[ ] milk`n") 'a checkbox does not tick under unsaved typing' (Text $Note)
        OpenSheet
        Check ((BoxText) -eq "[ ] milk`r`nX") 'reopening shows the kept typing' (BoxText)
    } finally { Set-ItemProperty $Note IsReadOnly $false }
    ClickElsewhere
    Check ((Text $Note) -eq "[ ] milk`nX`n") 'once the file is writable, the next close saves it' (Text $Note)
    ClickBox1
    Check ((Text $Note) -eq "[x] milk`nX`n") 'and the checkboxes work again' (Text $Note)

    Section 'The box opens scrolled to what the sheet shows'
    SeedText ((1..30 | ForEach-Object { "line $_" }) -join "`n")
    Skin 'Scroll(10)'
    OpenSheet
    Check ((FirstVisibleLine) -eq 10) 'scrolled ten rows down, the box shows line 11 at the top' "first visible: $(FirstVisibleLine)"
    ClickElsewhere
    Check ((Text $Note) -eq ((1..30 | ForEach-Object { "line $_" }) -join "`n")) 'an edit that typed nothing writes nothing'

    Section 'Characters beyond ASCII'
    SeedText "[ ] кава`n"
    OpenSheet
    Check ((BoxText) -eq "[ ] кава`r`n") 'a UTF-8 note reads correctly' (BoxText)
    Keys 'café 🍵'
    ClickElsewhere
    Check ((Text $Note) -eq "[ ] кава`ncafé 🍵`n") 'and is written back as UTF-8' (Text $Note)

    Section 'A note from before UTF-8'
    Seed ([byte[]](0x63, 0x61, 0x66, 0xE9, 0x20, 0x80, 0x0A))          # "café €" in Windows-1252
    OpenSheet
    Check ((BoxText) -eq "café €`r`n") 'a Windows-1252 note reads as 1252' (BoxText)
    Keys '!'
    ClickElsewhere
    Check ((Text $Note) -eq "café €`n!`n") 'and its first edit writes it as UTF-8' (Text $Note)

    Section 'A byte-order mark does not hide the first checkbox'
    Seed ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::ASCII.GetBytes("[ ] milk`n"))
    ClickBox1
    $b = Bytes $Note
    Check (($b.Length -ge 3) -and $b[0] -eq 0xEF -and ([Text.Encoding]::ASCII.GetString($b, 3, $b.Length - 3) -eq "[x] milk`n")) 'row 1 ticks, and the mark is kept'

    Section 'A note that cannot be read'
    Remove-Item $Note
    New-Item -ItemType Directory $Note | Out-Null                       # a folder where the file should be
    try {
        OpenSheet
        Check (-not (IsOpen)) 'the box does not open over it'
    } finally { Remove-Item $Note }
    Start-Sleep -Milliseconds 2200
    SeedText "[ ] milk`n"
    ClickBox1
    Check ((Text $Note) -eq "[x] milk`n") 'and the skin is not left waiting for it' (Text $Note)
}
finally {
    if (IsOpen) { ClickElsewhere }
    if (Test-Path $Note -PathType Container) { Remove-Item $Note }
    foreach ($pair in @(@($Note, $savedNote), @($Bak, $savedBak))) {
        if ($null -eq $pair[1]) { Remove-Item $pair[0] -ErrorAction SilentlyContinue }
        else { [IO.File]::WriteAllBytes($pair[0], $pair[1]) }
    }
    Remove-Item "$Note.tmp" -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed) { Write-Host "$script:failed failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed'
