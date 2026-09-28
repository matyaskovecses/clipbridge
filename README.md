# ClipBridge

**Copy on your Windows PC, paste on your iPhone, and the other way round.** Text, pictures and files travel directly over your home Wi-Fi, with no app to install on the phone, no account and no cloud service in between.

## Why this exists

Apple's Universal Clipboard only works between Apple devices. If your computer runs Windows, there is no built-in way to copy something on the PC and paste it on your iPhone. ClipBridge fills that gap with a small program on the PC and a few Shortcuts on the iPhone (the Shortcuts app is built into iOS).

## What it does

- **Text** copied on the PC can be pasted on the iPhone, and text copied on the iPhone can be pasted on the PC.
- **Pictures**: screenshots and copied images go from the PC to the iPhone. Photos from the iPhone land on the PC clipboard, ready to paste.
- **Files**: share photos, PDFs or any other file from the iPhone. They're saved in `Downloads\From iPhone` and put on the PC clipboard, so Ctrl+V pastes them into a folder, a chat app or an email. Files copied in Explorer can go to the iPhone too; several at once arrive as one `.zip`.
- **Quiet**: it lives as a small clipboard icon next to the clock and starts with Windows. There's no window to keep open.
- **Nothing to install**: it runs on Windows PowerShell, which comes with Windows 10 and 11. No admin rights needed.

## How it works

ClipBridge runs a tiny web server on your PC that only answers on your home network. Your iPhone Shortcuts talk to it through a personal web address (URL) that includes a random password, called the *token*. The iPhone can't share its clipboard in the background, so the Shortcuts run when you open or leave an app, or when you tap them (details in [step 4](#4-automations-make-it-as-automatic-as-possible)).

---

## Set up the PC

1. **Download ClipBridge.** On this page, click the green **Code** button, then **Download ZIP**.
2. **Unblock the ZIP** (this stops Windows from warning about every file). Right-click the ZIP file, choose **Properties**, tick **Unblock** at the bottom if it's there, and click **OK**.
3. **Extract it to a folder you'll keep**, for example `Documents\ClipBridge`. ClipBridge runs from this folder, so don't leave it in a place you clean out regularly.
4. **Double-click `Install_ClipBridge.bat`.** This starts ClipBridge now and every time you sign in to Windows. If Windows says *"Windows protected your PC"*, click **More info**, then **Run anyway**. A window shows what happened; press any key to close it.
5. **Allow it through Windows Firewall.** The first time, Windows asks whether *Windows PowerShell* may use the network. Tick **Private networks**, untick **Public networks**, and click **Allow access**. This may need an administrator's approval. If you missed the question, see [Troubleshooting](#troubleshooting).
6. **Make sure Windows treats your Wi-Fi as private.** Open **Settings → Network & internet → Wi-Fi →** your network, and set **Network profile type** to **Private**.
7. **Find the icon.** Look for a small blue clipboard next to the clock. If it isn't there, click the **^** arrow; you can drag the icon onto the taskbar to keep it in view. Point at it to see its status, for example *ClipBridge: running on 192.168.1.23:8765*.
8. **Get your URL.** Click the icon and choose **Copy iPhone URL**. Your personal URL is now on the PC clipboard. It looks like this, but with your own numbers and letters:

   ```
   http://192.168.1.23:8765/clip?t=k7m2p9x4q8r3t6w5
   ```

   To get it onto the iPhone, send it to yourself (email or a chat app) or simply type it. Keep it private: it works like a password.

> **Tip:** set up *PC Paste* (below) first by typing the URL. After that you can click **Copy iPhone URL** on the PC and run *PC Paste* on the iPhone, and the URL lands on the iPhone clipboard, ready to paste into the other Shortcuts.

## Set up the iPhone

You'll make three Shortcuts and two automations in the **Shortcuts** app. Wherever the steps say *your URL*, use the URL from step 8 above.

In the **Get Contents of URL** action, tap the small arrow (or **Show More**) to see the **Method**, **Headers** and **Request Body** settings.

### 1. "PC Paste": bring the PC clipboard to the iPhone

1. In Shortcuts, tap **+** to make a new shortcut and name it **PC Paste**.
2. Add the action **Get Contents of URL**. Set the URL to your URL with `&new=1` added at the end:
   `http://192.168.1.23:8765/clip?t=k7m2p9x4q8r3t6w5&new=1`
   Leave **Method** on **GET**.
3. Add the action **If**. Set it to: If **Contents of URL** **has any value**.
4. Inside the If (between **If** and **Otherwise**), add **Copy to Clipboard** and make sure it copies **Contents of URL**.

`&new=1` means "only if something new was copied on the PC". When nothing changed, the shortcut does nothing, so it never overwrites what you copied on the iPhone.

### 2. "Send to PC": put the iPhone clipboard on the PC

1. Make a new shortcut named **Send to PC**.
2. Add the action **Get Clipboard**.
3. Add **Get Contents of URL**:
   - URL: your URL (without `&new=1`): `http://192.168.1.23:8765/clip?t=k7m2p9x4q8r3t6w5`
   - Method: **POST**
   - Request Body: **File**, then tap **File** and choose **Clipboard**.

Text becomes the PC clipboard. A picture is saved in `Downloads\From iPhone` and put on the PC clipboard.

### 3. "File to PC": share photos and files from any app

1. Make a new shortcut named **File to PC**.
2. Tap the **ⓘ** (Details) button and turn on **Show in Share Sheet**. Back in the editor, the top now says *Receive **Any** input from **Share Sheet***. Tap **If there's no input: Continue** and change it to **Get Clipboard**. That way you can also run it on its own to send whatever you copied.
3. Add **Repeat with Each** and make sure it repeats with each item in **Shortcut Input**.
4. Inside the repeat, add **Get Contents of URL**:
   - URL: your URL with `/clip` changed to `/file`: `http://192.168.1.23:8765/file?t=k7m2p9x4q8r3t6w5`
   - Method: **POST**
   - Headers: tap **Add new header**. In **Key**, type `X-Filename`. In **Text**, insert the variable **Repeat Item**, then tap it and choose **Name**. (**Key** is the header's name and **Text** is its value.)
   - Request Body: **File**, and choose **Repeat Item**.

Now in Photos, Files or any other app, tap **Share → File to PC**. The files are saved in `Downloads\From iPhone` and put on the PC clipboard. Several files sent together are pasted together.

### 4. Automations: make it as automatic as possible

iOS doesn't let any app read or watch the clipboard in the background, so a live, always-on sync isn't possible on the iPhone. The closest you can get is to run the Shortcuts whenever you open or leave an app:

1. In Shortcuts, go to the **Automation** tab and tap **+** (**New Automation**), then **App**.
2. Tap **Choose** and pick the apps you copy and paste in, such as Messages, Notes, Safari, Mail and WhatsApp. Select **Is Opened** only, then choose **Run Immediately**. Tap **Next** and pick **PC Paste**.
3. Make a second automation the same way, but with **Is Closed** only and **Run Immediately**. Choose **New Blank Automation** and add two actions: **Run Shortcut: PC Paste**, then **Run Shortcut: Send to PC**.

Opening one of those apps now brings over whatever you copied on the PC. Leaving the app first checks the PC, then sends what you copied on the iPhone. If the phone would only send back what it just got, ClipBridge recognizes it and ignores it.

You can turn off **Notify When Run** in each automation if the banners bother you.

### 5. Optional: Back Tap

Tap the back of your iPhone to run a shortcut: **Settings → Accessibility → Touch → Back Tap**. For example, set **Double Tap** to **PC Paste** and **Triple Tap** to **Send to PC**.

---

## Everyday use

| You want to... | Do this |
|---|---|
| Copy on the PC, paste on the iPhone | Copy as usual (Ctrl+C), then open an app on the iPhone, or run **PC Paste**. Paste. |
| Copy on the iPhone, paste on the PC | Copy as usual, then leave the app, or run **Send to PC**. Press Ctrl+V on the PC. |
| Send photos or files to the PC | **Share → File to PC**. Paste them with Ctrl+V, or open `Downloads\From iPhone`. |
| Send files from the PC to the iPhone | Copy them in Explorer, then run **PC Paste**. Paste them in the Files app or a chat. |

## The tray icon

Click (or right-click) the clipboard icon next to the clock:

- **Copy iPhone URL** copies your personal URL, with the token, to the PC clipboard. It's kept out of Windows clipboard history (Win+V).
- **Open received files** opens `Downloads\From iPhone`.
- **Show log** opens ClipBridge's log in Notepad.
- **Notifications** (off by default) shows a notification for every transfer.
- **Restart** and **Quit**.

Point at the icon to see the PC's address and the time of the last transfer. A **yellow warning sign** instead of the clipboard means ClipBridge can't use its network port (see [Troubleshooting](#troubleshooting)).

## Security

- **Your network only.** The iPhone talks to the PC directly over your Wi-Fi. Nothing goes through the internet or a cloud service.
- **The token in the URL is the only lock.** Anyone on your network who has your URL can read your PC clipboard and put files into `Downloads\From iPhone`. Treat the URL like a password, and don't share screenshots of your Shortcuts.
- **No encryption.** ClipBridge uses plain HTTP. On your own password-protected home Wi-Fi that's usually fine. On shared networks (office, dorm, hotel, café), other people could see what you transfer, including the token. That's why you allow it only for **Private** networks in the firewall; on networks Windows treats as **Public**, it is blocked.
- **Never port-forward ClipBridge** on your router or expose it to the internet in any other way.
- The firewall permission you give applies to *Windows PowerShell* on private networks, because that's the program ClipBridge runs in.
- **To change the token:** quit ClipBridge, delete `clipbridge-token.txt` in the ClipBridge folder, start it again with `Start_ClipBridge.bat`, and update the URL in your Shortcuts.
- `clipbridge-token.txt` and `clipbridge-url.txt` contain your token and your PC's addresses. They're created on your PC and are never part of this repository.

## Troubleshooting

**The iPhone can't connect (the shortcut shows an error or times out)**

- **Is ClipBridge running?** Look for its icon (click the **^** arrow next to the clock). If it's missing, double-click `Start_ClipBridge.bat`.
- **Same Wi-Fi?** The iPhone must be on the same network as the PC, not on mobile data or a guest network. Some routers keep devices on a guest network apart from each other.
- **Firewall:** open **Windows Security → Firewall & network protection → Allow an app through firewall → Change settings**. Find **Windows PowerShell** and tick **Private**. This needs administrator rights.
- **Network set to Public:** Windows blocks ClipBridge on public networks. Set your Wi-Fi to **Private** (see step 6 of the PC setup).
- **The address changed:** your router can give the PC a new address. Point at the tray icon to see the current one, and update your Shortcuts if it's different. To stop it from changing, reserve the address for your PC in your router's settings (often called *DHCP reservation*).
- **VPN or virtual network adapters:** VPNs (such as Cloudflare WARP or NordVPN) and tools like Hyper-V, WSL or VirtualBox add extra addresses to the PC. ClipBridge picks your Wi-Fi or Ethernet address, and `clipbridge-url.txt` in the ClipBridge folder lists all of them. The right one usually starts with `192.168.` or `10.`. Some VPNs also block local network traffic; allow *LAN access* in the VPN's settings, or pause it.
- **iPhone permissions:** in **Settings → Privacy & Security → Local Network**, make sure **Shortcuts** is on. The first time each shortcut connects to your PC, iOS asks for permission; choose **Always Allow**.

**The shortcut says "bad token"**: the token in the URL doesn't match. Click **Copy iPhone URL** again and update the URL in your Shortcuts.

**The icon is a yellow warning sign**: port 8765 is used by another program, or Windows reserved it (Hyper-V and WSL sometimes do). ClipBridge retries every 15 seconds, so restarting the PC often fixes it. To use a different port, open the ClipBridge folder in Explorer, click the address bar, type `cmd` and press Enter. Then run `Install_ClipBridge.bat -Port 8766` and change `8765` to `8766` in your Shortcuts.

**Photos arrive as `.heic` files that Windows can't open**: iPhones save photos as HEIC by default. You can:
- install **HEIF Image Extensions** from the Microsoft Store, or
- in **File to PC**, add **Convert Image** (to **JPEG**) inside the repeat, before **Get Contents of URL**, and choose **Converted Image** as the Request Body. Only do this if you use the shortcut for photos; it can't handle other files. Or
- set **Settings → Camera → Formats → Most Compatible** so new photos are saved as JPEG.

**The iPhone keeps asking "Allow Paste"**: iOS asks before a shortcut reads the clipboard. Open **Settings → Apps → Shortcuts** (on older iOS: **Settings → Shortcuts**) and set **Paste from Other Apps** to **Allow**.

**Where is the log?** Click the tray icon and choose **Show log**, or paste `%LOCALAPPDATA%\ClipBridge\clipbridge.log` into Explorer's address bar. The log lists transfers and errors, with file names and text lengths but never the text itself. It's kept to about 1 MB.

## Limitations

- **No background sync on the iPhone.** iOS doesn't allow it, so transfers happen when a shortcut runs: by hand, with Back Tap, or through the app automations.
- **Both devices must be on the same network.**
- **The PC must be on, awake and signed in.** ClipBridge runs in your Windows session and can't wake a sleeping PC.
- **One item at a time.** It moves the current clipboard; there's no clipboard history.
- Pictures from the PC arrive as PNG files; several files or a folder arrive as one `.zip`.
- Plain HTTP, without encryption (see [Security](#security)).
- One transfer at a time: while a big file is on its way, other requests wait.

## Similar projects

| | ClipBridge | [clipboard-bridge](https://github.com/copypasteengine/clipboard-bridge) | [common-clipboard](https://github.com/cmdvmd/common-clipboard) |
|---|---|---|---|
| Computer | Windows | Windows, macOS, Linux | Windows |
| Phone | iPhone (Shortcuts) | Android app; iPhone (Shortcuts) | iPhone (Shortcuts + the Scriptable app) |
| Text | Yes | Yes | Yes |
| Pictures | Yes | No (text only) | Yes |
| Files | Yes | No | No |
| Background sync on the iPhone | No | No | No |

These facts come from each project's README (September 2026). clipboard-bridge describes itself as "Plain Text Only" and points to other tools for images and files. common-clipboard transfers "unicode text and images", and its shortcut keeps running while the Shortcuts app stays open. None of them can sync on the iPhone in the background, because iOS doesn't let apps read the clipboard in the background. ClipBridge's tray icon was inspired by clipboard-bridge's tray app.

## For developers: the HTTP API

The token goes in the query string (`?t=TOKEN`) or in an `X-Token` header. The default port is 8765.

| Request | What it does |
|---|---|
| `GET /clip?t=TOKEN` | Returns the PC clipboard: text as `text/plain; charset=utf-8`, a picture as PNG, one copied file as it is, or several files or a folder as a `.zip`. Files come with a `Content-Disposition` file name. An empty clipboard gives an empty reply. |
| `GET /clip?t=TOKEN&new=1` | The same, but an empty reply if nothing was copied on the PC since the phone last received or sent something. |
| `POST /clip?t=TOKEN` | A text body (UTF-8) becomes the PC clipboard. Anything else, such as a picture or a PDF, is saved like `/file`. |
| `POST /file?t=TOKEN` | The body is a file, with an optional `X-Filename: name` header (or `?name=`). It's saved to `Downloads\From iPhone` and put on the PC clipboard. |

- Replies to POST are `ok`, or `same` if the content matches something transferred recently (the last 30 transfers, in either direction) and was ignored. `PUT` works like `POST`.
- A body counts as text if it has no file name, doesn't start like a known file type (JPEG, PNG, GIF, PDF, ZIP, HEIC, MP4/MOV), has a text or empty `Content-Type`, is smaller than 5 MB and is valid UTF-8.
- Files that arrive within 8 seconds of each other go on the clipboard together.
- A wrong or missing token gets `403`, other paths `404`, and other methods `405`. Uploads need a `Content-Length` header.
- The server listens on all of the PC's network adapters and answers one request at a time.

For example, with curl from another computer on the same network:

```
curl "http://192.168.1.23:8765/clip?t=YOUR-TOKEN"
curl --data-binary @photo.jpg -H "X-Filename: photo.jpg" "http://192.168.1.23:8765/file?t=YOUR-TOKEN"
```

## Updating, moving and uninstalling

- **Update:** download the new version and copy its files over the old ones. Keep your `clipbridge-token.txt` so your Shortcuts keep working. ClipBridge notices the new `ClipBridge.ps1` and restarts itself within a few seconds.
- **Move the folder:** after moving it, run `Install_ClipBridge.bat` again from the new place.
- **Uninstall:** double-click `Uninstall_ClipBridge.bat`. It stops ClipBridge and removes it from Windows startup. Then delete the ClipBridge folder, and on the iPhone delete the Shortcuts and automations. Files you received stay in `Downloads\From iPhone`, and the log and settings are in `%LOCALAPPDATA%\ClipBridge` if you want to remove those too.

## What's in the folder

| File | What it is |
|---|---|
| `ClipBridge.ps1` | The program itself, a PowerShell script |
| `Start_ClipBridge.bat` | Starts ClipBridge in the tray |
| `Install_ClipBridge.bat` | Starts it now and whenever you sign in to Windows |
| `Uninstall_ClipBridge.bat` | Stops it and removes it from Windows startup |
| `clipbridge-token.txt` | Created on first start: your secret token. Don't share it. |
| `clipbridge-url.txt` | Created on each start: your URLs and addresses, for reference. Don't share it. |

## License

MIT. See [LICENSE](LICENSE).
