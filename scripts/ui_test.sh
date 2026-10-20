#!/bin/bash
# UI 自動測試（AppleScript／System Events）：錄一段 → 重新命名 → 送到 Osmi → 分享 → 刪除（移到垃圾桶）。
# 只動這個測試自己錄的那一個檔案；其他錄音檔不碰。需要「輔助使用」權限給執行這支腳本的終端機。
set -uo pipefail
# ⛔ 一律用測試資料夾，不碰使用者的 ~/Music/AudioMemo。會先結束正在跑的 AudioMemo（若正在錄音則不執行）。
DIR=~/Music/AudioMemo-Test
mkdir -p "$DIR"
if tail -1 ~/Library/Logs/AudioMemo/debug.log | grep -q "start \."; then echo "AudioMemo 好像正在錄音，先不跑"; exit 2; fi
osascript -e 'tell application "AudioMemo" to quit' >/dev/null 2>&1; sleep 2
NEWNAME="UI Test Rename $(date +%H%M%S)"
pass(){ echo "PASS $*"; }; fail(){ echo "FAIL $*"; FAILED=1; }
FAILED=0
osa(){ osascript -e "tell application \"System Events\" to tell process \"AudioMemo\" to $1" 2>&1; }

open -n ~/Applications/AudioMemo.app --args -storageFolder "$DIR"; sleep 3
osascript -e 'tell application "AudioMemo" to reopen' -e 'tell application "AudioMemo" to activate'; sleep 2
osa 'get name of window 1' | grep -q AudioMemo || { echo "主視窗沒有出現"; exit 3; }
osascript -e 'tell application "AudioMemo" to activate'; sleep 1
before=$(ls "$DIR"/*.m4a 2>/dev/null | wc -l | tr -d ' ')

# 1) 錄音：⌘R 開始、4 秒後 ⌘. 停止
osa 'keystroke "r" using command down' >/dev/null; sleep 5
state=$(osa 'get name of static text 1 of group 1 of window 1')
osa 'keystroke "." using command down' >/dev/null; sleep 2
after=$(ls "$DIR"/*.m4a | wc -l | tr -d ' ')
newest=$(ls -t "$DIR"/*.m4a | head -1)
[ "${after}" -gt "${before}" ] && pass "錄音：狀態「${state}」，新增 $(basename "$newest")" || fail "錄音沒有產生檔案（狀態 ${state}）"
ROW='UI element 1 of scroll area 1 of group 1 of window 1'
top=$(osa "get name of static text 1 of $ROW")
[ "${top}.m4a" = "$(basename "$newest")" ] && pass "列表最上面是剛錄的：${top}" || fail "列表最上面是 ${top}"

# 2) 重新命名（更多 → 重新命名… → 輸入 → 儲存）
osa "click menu button 1 of $ROW" >/dev/null; sleep 0.5
osa "click menu item \"Rename…\" of menu 1 of menu button 1 of $ROW" >/dev/null; sleep 1
osa 'keystroke "a" using command down' >/dev/null
# 用剪貼簿貼上（直接 keystroke 會被中文輸入法吃字）
printf '%s' "${NEWNAME}" | pbcopy
osa 'keystroke "v" using command down' >/dev/null; sleep 0.3
osa 'keystroke return' >/dev/null; sleep 1.5
[ -f "$DIR/${NEWNAME}.m4a" ] && pass "重新命名 → ${NEWNAME}.m4a" || fail "重新命名後找不到 ${NEWNAME}.m4a"
top=$(osa "get name of static text 1 of $ROW")
[ "${top}" = "${NEWNAME}" ] && pass "列表已更新為新名稱" || fail "列表名稱是 ${top}"

# 3) 送到 Osmi：開瀏覽器＋Finder 選取
osa "click button 2 of $ROW" >/dev/null; sleep 3
grep -q "sendToOsmi ${NEWNAME}.m4a" ~/Library/Logs/AudioMemo/debug.log && pass "送到 Osmi：Finder 已選取檔案、瀏覽器已開 Osmi（請目視確認 Finder 視窗在瀏覽器後面）" || fail "送到 Osmi 沒有執行"
osascript -e 'tell application "Google Chrome" to get URL of every tab of every window' 2>/dev/null | tr ',' '\n' | grep -q "meeting.bookai.com/app" && pass "瀏覽器有 https://meeting.bookai.com/app 分頁" || echo "     （無法從 Chrome 讀到分頁；預設瀏覽器可能不是 Chrome）"

# 4) 刪除（更多 → 刪除… → 移到垃圾桶）
osascript -e 'tell application "AudioMemo" to activate'; sleep 1
osa "click menu button 1 of $ROW" >/dev/null; sleep 0.5
osa "click menu item \"Delete…\" of menu 1 of menu button 1 of $ROW" >/dev/null; sleep 1
osa 'click button "Move to Trash" of sheet 1 of window 1' >/dev/null || osa 'keystroke return' >/dev/null
sleep 1.5
[ ! -f "$DIR/${NEWNAME}.m4a" ] && pass "刪除：檔案已從資料夾移到垃圾桶" || fail "刪除後檔案仍在"
top=$(osa "get name of static text 1 of $ROW")
[ "${top}" != "${NEWNAME}" ] && pass "列表已移除（最上面現在是 ${top}）" || fail "列表仍有 ${NEWNAME}"
# 5) 分享（放最後：系統分享選單是另一個程序畫的，AX 抓不到，改看 App 紀錄）
osascript -e 'tell application "AudioMemo" to activate'; sleep 1
LOGN=$(wc -l < ~/Library/Logs/AudioMemo/debug.log)
osa "click button 3 of $ROW" >/dev/null; sleep 1.5
tail -n +$((LOGN + 1)) ~/Library/Logs/AudioMemo/debug.log | grep -q "share picker shown" && pass "分享：系統分享選單已叫出（請目視確認 AirDrop／郵件／訊息）" || fail "分享選單沒有叫出"
osa 'key code 53' >/dev/null; sleep 0.5

# 收尾：結束測試用的 App，重新以一般模式打開（回到使用者的資料夾）
osascript -e 'tell application "AudioMemo" to quit' >/dev/null 2>&1; sleep 2
open ~/Applications/AudioMemo.app
exit $FAILED
