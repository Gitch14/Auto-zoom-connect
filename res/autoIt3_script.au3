; Retrieve meeting ID from command line argument
Local $meetingId = $CmdLine[1]
Local $password = $CmdLine[2]

; Wait for the Zoom conference window to appear (wait for 30 seconds)
WinWait("[CLASS:ZPPTMainFrmWndClassEx]", "", 30)

; If the window is found, activate it and send "Войти" (Enter) key
If WinExists("[CLASS:ZPPTMainFrmWndClassEx]") Then
    WinActivate("[CLASS:ZPPTMainFrmWndClassEx]")
    Send("{ENTER}")
Else
    ; Handle the case where the Zoom window doesn't appear within the timeout
    MsgBox(16, "Error", "Zoom window not found")
    Exit
EndIf

; Wait for the waiting meeting ID window to appear (wait for 30 seconds)
WinWait("[CLASS:zWaitingMeetingIDWndClass]", "", 30)

; Handle the waiting meeting ID window (assuming you have a button or some action to perform here)
; For example, sending another Enter key press
If WinExists("[CLASS:zWaitingMeetingIDWndClass]") Then
    WinActivate("[CLASS:zWaitingMeetingIDWndClass]")
    ; Send the extracted meeting ID
    Send($meetingId)
    Send("{ENTER}")
Else
    ; Handle the case where the waiting meeting ID window doesn't appear within the timeout
    MsgBox(16, "Error", "Waiting meeting ID window not found")
    Exit
EndIf

; Wait for the waiting meeting password window to appear (wait for 30 seconds)
WinWait("[CLASS:zWaitingMeetingIDWndClass]", "", 30)

If WinExists("[CLASS:zWaitingMeetingIDWndClass]") Then
    WinActivate("[CLASS:zWaitingMeetingIDWndClass]")
    ; Send the extracted meeting ID
    Send($password)
    Send("{ENTER}")
Else
    ; Handle the case where the waiting meeting password window doesn't appear within the timeout
    MsgBox(16, "Error", "Waiting meeting password window not found")
    Exit
EndIf


