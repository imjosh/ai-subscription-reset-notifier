param(
  [string]$message = "Your AI subscription usage has reset."
)

$notificationVolume = 0.5
$popupTitle = "Subscription reset"
$waitUntilOkSeconds = 0 # 0 means the popup stays up until the user clicks OK.
$informationIcon = 64 # WScript.Shell.Popup icon ID for information

$hour = (Get-Date).Hour
if ($hour -ge 9 -and $hour -lt 22) {
  if (-not ("AutoAudio" -as [type])) {
    & ("C:\Users\Josh\Documents\GitHub\personal\automate-windows-audio\Automate-Windows-Audio.ps1")
  }
  [AutoAudio]::SetVolume($notificationVolume)
  [AutoAudio]::PlaySoundFile((Join-Path $PSScriptRoot "universfield-cash-register-open-ding-559401.mp3"))
}

# WScript.Shell.Popup: body text max 1024 chars; line breaks use CR only.
$popupMessageMaxLength = 1024
$message = ($message -replace "`r`n", "`r") -replace "`n", "`r"
if ($message.Length -gt $popupMessageMaxLength) {
  $message = $message.Substring(0, $popupMessageMaxLength)
}

$shell = New-Object -ComObject WScript.Shell
$shell.Popup($message, $waitUntilOkSeconds, $popupTitle, $informationIcon)
