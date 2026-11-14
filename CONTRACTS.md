# Lazy Send contracts

Lazy Send moves text, links, files and whole photo galleries between a computer and a phone, in both directions, between two computers, and between two phones when one of them is an iPhone or an Android phone hosting. This file is the protocol and the rules both sides keep. The Windows core is C# in `windows/LazySend.Core/Link`; the Android app (`android/`), the iPhone app (`ios/` and the Swift package at the root), the Windows app and the Mac app (`mac/`, with the server in `Sources/LazySendServer`) follow this file.

The phone link is Lazy Print's (its CONTRACTS.md, "The phone link"), copied and changed: the same TLS server, pinning, pairing and limits, with the print package and the sync folder left out and uploads, a gallery index and a computer-to-phone outbox added. The apps do not share pairings, ports or files with any other Lazy app.

## Identifiers

| Thing | Value |
| --- | --- |
| Name in text, in code | Lazy Send, LazySend |
| Namespace (Windows core) | `LazySend.Core` |
| Protocol version | 1, in the pairing code and every hello, health and pair answer |
| Pairing code | `lazysend://pair?v=1&id=&n=&fp=&a=&p=&t=` |
| Short code | 8 characters of Crockford base32, shown `XXXX-XXXX` (see Short code) |
| DNS-SD service | `_lazysend._tcp`, TXT keys `v` (protocol version), `id` (the computer's id) and `n` (its name, at most 64 UTF-8 bytes; left out when empty; the Windows and Mac apps send it, and a guest lists a host that sends none by its instance name) |
| Port | 52734 first (Lazy Scan 52731, Lazy Print 52732, Lazy PDF 52733), any free port when taken |
| `service` in health answers | `lazysend` |
| Settings | `%APPDATA%\Lazy Send\devices.json`, `hosts.json`, `settings.json` |
| State | `%LOCALAPPDATA%\Lazy Send\` (see Storage) |
| Mac | `~/Library/Application Support/Lazy Send/` (see Storage on the Mac) |

Ids (a computer's, a phone's, an item's) are 8 to 64 characters from letters, digits, `-` and `_`, so they are safe as file names. The server makes item ids as 32 hex digits.

## Pairing

The host is the server and the guest is the client: the guest opens every connection, and the host never connects out. A computer is a host and also a guest of other computers (see A computer as a guest); a phone is a guest, and an iPhone is also a host while its app is open (see The iPhone as a host). Below, "the computer" is the host and "the phone" the guest unless a guest that is a computer is meant. The connection is HTTP/1.1 over TLS 1.2 or 1.3 with the host's own certificate, self-signed ECDSA P-256. The guest does not trust a certificate authority; it trusts the one key whose fingerprint came in the pairing code, the SHA-256 of the certificate's SubjectPublicKeyInfo (so a renewed certificate on the same key keeps every pin).

The code the computer shows as a QR is the URI above. `v` is the protocol version, `id` the computer's id, `n` its name, `fp` the fingerprint as base64url without padding (43 characters), `a` a comma-separated list of its addresses (each percent-encoded, at most 8, IPv4 first), `p` the port and `t` the pairing token, base64url of 16 random bytes. Values are percent-encoded UTF-8; unknown parameters are ignored so later versions can add some. A code with a higher `v` than the app speaks is refused with a message to update.

The addresses are those of every interface that is up, whatever its type, loopback and IPv6 link-local ones left out. USB networking is not special: an iPhone's Personal Hotspot over USB gives the computer an address such as 172.20.10.x and Android USB tethering usually 192.168.42.x (not on a Mac, which has no driver for it), and both are in the list like a Wi-Fi address. Self-assigned 169.254.x.x addresses go last. The phone tries the addresses in turn and checks the fingerprint on whichever answers. `hello` lists the same addresses as they are at that moment, so a phone paired over Wi-Fi learns the computer's USB tether address once it has reached it any way at all, and keeps the list up to date.

The server listens on every interface, IPv4 and IPv6, on one port. It answers only peers from loopback, private, link-local and unique-local addresses, or from the subnet of one of the computer's own addresses (which is how a 100.64.0.0/10 address, as Tailscale uses, gets in); anything else is closed before TLS starts.

1. The user opens pairing on the computer. A session starts: a random token, good for 5 minutes and for one pairing.
2. The phone scans the code and sends `POST /v1/pair` with the token and who it is.
3. The computer checks the token, then asks the user on screen whether this phone may pair. Without an answer within 120 seconds the pairing is declined, and the default answer when nothing is wired to answer is decline.
4. On approval the computer makes a 32-byte secret for the phone, stores only its SHA-256, and answers with the secret once. The phone counts as paired only once the answer has been written to it; when the write fails the phone is forgotten again.
5. Every later request carries `X-Device-Id: <phone id>` and `Authorization: Bearer <secret>` (the secret as base64url). A wrong id or secret gets 401 and counts as a failure.

Tokens are compared in constant time. Five wrong tokens from one address refuse that address for the rest of the session and 25 from all addresses together close the session (a wrong short code counts as a wrong token). A closed, used or expired session answers `pairingClosed`. At most 16 phones can be paired; the answer for a 17th is 409 `tooManyDevices`. Pairing again with the same phone id replaces its entry and secret. Pairings are not shared with the other Lazy apps.

### Short code

A session also has a short code for a guest that cannot scan: 8 characters from `0123456789ABCDEFGHJKMNPQRSTVWXYZ` (Crockford base32, no I, L, O or U), shown as `XXXX-XXXX`. `POST /v1/pair` takes it as `token` in place of the 22-character token. Case, dashes and spaces are ignored, and it is compared in constant time. It belongs to the same session, so either one uses the session up, and it works within the same 5 minutes and under the same limits on wrong tokens, which is what makes 40 bits enough.

A guest that typed the short code has no fingerprint yet. To make a man in the middle visible, a match code is compared on both screens, and the order matters because the code itself is a secret that a computer pretending to be the host would learn:

1. The guest asks `GET /v1/health` at the host's addresses in turn, takes the fingerprint of the certificate it meets and works out the match code from it and the code it was given.
2. The guest shows the match code and asks the user whether the host's screen shows the same digits next to its short code. The host works them out as soon as the session opens, from its own fingerprint, and shows them with the code. On no, the guest stops and sends nothing.
3. Only on yes does the guest send `POST /v1/pair` with the code, over a connection pinned to the fingerprint it met. The host still asks its user before it answers, and shows the digits again.

The match code is:

- Paired from a QR code or a pasted link, the guest holds the fingerprint already, and both screens show the check code phones show: the first four bytes of the fingerprint as a big-endian number modulo one million, six digits with leading zeros.
- Paired by short code, the same six digits are taken from SHA-256 over the 32 fingerprint bytes followed by the 8 canonical characters of the short code. The certificate is chosen before the code is known, so a man in the middle cannot grind a key until the plain check code of the real certificate comes out, as it could if the digits came from the fingerprint alone.

Digits are shown three and three with a space ("066 051"). For the fingerprint bytes 0x00 to 0x1F the check code is 066 051, and with the short code `7KQ2M9XD` the match code is 987 292; both servers' tests hold this vector.

The host works out which one applies from the shape of `token` (22 characters of base64url, or 8 of the alphabet), so existing phones, which only send tokens, see no change.

## Routes

Requests and answers are JSON (`application/json; charset=utf-8`) unless said otherwise, with camelCase names; unknown names are ignored. Everything but `health` and `pair` needs the two headers above. Errors are `{"error": "<code>", "message": "<sentence to show>"}`, plus `offset` for `offsetMismatch`. The codes are stable: `unauthorized`, `pairingClosed`, `tokenInvalid`, `tokenExpired`, `tokenUsed`, `declined`, `tooManyDevices`, `tooLarge`, `rateLimited`, `notFound`, `methodNotAllowed`, `badRequest`, `lengthRequired`, `busy`, `offsetMismatch`, `hashMismatch`, `diskFull`, `rangeNotSatisfiable`, `changed`, `serverError`.

| Route | Request | Answer |
| --- | --- | --- |
| `GET /v1/health` | none needed; with credentials it also says whether the phone is still paired (a wrong secret is 401) | 200 `{service, protocolVersion, paired}` |
| `POST /v1/pair` | `{token, phoneId, phoneName, platform, appVersion}` | 200 `{protocolVersion, desktopId, desktopName, deviceSecret}`; 403 `pairingClosed`, `tokenInvalid`, `tokenExpired`, `tokenUsed`, `declined`; 409 `tooManyDevices` |
| `GET /v1/hello` | | 200 `{protocolVersion, desktopId, desktopName, maxChunkBytes, addresses}` |
| `DELETE /v1/devices/self` | | 204; the phone is forgotten, and so are what it had begun and not finished and what waited for it |
| `POST /v1/items` | `{kind, ...}`, below | 201 or 200, below |
| `GET /v1/items/{id}` | | 200 `{id, offset, done}`; 404 for an unknown item or another phone's |
| `PUT /v1/items/{id}/data` | header `X-Offset: <n>`, `Content-Length`, the bytes | 200 `{id, offset, done}` |
| `POST /v1/gallery/check` | `{ids: [...]}`, at most 1000 | 200 `{missing: [...]}` |
| `GET /v1/outbox?wait=<seconds>` | | 200 `{items: [...], more?}` |
| `GET /v1/outbox/{id}/data` | optional `Range: bytes=<n>-` | 200 or 206 with the file's bytes |
| `DELETE /v1/outbox/{id}` | | 204 |

### Guest to host

`POST /v1/items` takes `{kind: "text"|"link"|"file", text?, url?, name?, size?, mime?, modified?, sourceId?, sha256?}`.

- `text` needs `text`, at most 1 MiB of UTF-8 (413 over that, 400 when empty). It goes into the received history at once and the answer is 201 `{id, offset: 0, done: true}`.
- `link` needs `url`, an absolute `http` or `https` address of at most 8192 characters (400 otherwise; other schemes are refused because the app opens what arrives). Stored and answered as text is.
- `file` needs `name` and `size` (bytes, 0 or more); `mime` and `modified` (ISO 8601) are optional; `sourceId` is the phone's stable id for the asset (1 to 256 characters, no control characters); `sha256` is 64 hex digits of the whole file. The answer is 201 `{id, offset: 0, done: false}`, and the data goes up with `PUT`. An empty file is done at once. If the same `sourceId` already has a transfer in progress from this phone and the same size, its id and current offset are returned, as for a new one, instead of starting a second transfer; if the `sourceId` was received before, the answer is 200 `{id: "", offset: size, done: true, duplicate: true}` and nothing is sent. A drive that would drop under 1 GiB free after the file gets 507 `diskFull`. There is no limit on a file's size.

`PUT /v1/items/{id}/data` appends a chunk of at most 64 MiB at `X-Offset`.

- The offset must be the file's current length. Otherwise the answer is 409 `offsetMismatch` with `offset` set to the current length, and the phone continues from there. The whole body of such a refused chunk is read and dropped first, so the answer is never lost to a reset.
- A chunk without a `Content-Length` gets 411 `lengthRequired`; one that would end past the file's size, or whose offset is past it, gets 400; one over 64 MiB gets 413; one that would leave under 1 GiB free gets 507. An empty chunk at an offset equal to the size is not an error: it finishes a file whose part is already full but was never put in place, and answers as the last chunk does. An empty chunk anywhere else is 400 or 409.
- When the offset reaches `size` the item completes: the SHA-256, when given, is checked (a mismatch deletes the file and answers 422 `hashMismatch`, and the phone starts the file again with a new `POST`), the part file is renamed into place, the file's modified time is set from `modified` (dates before 1980 or after 2100 are ignored, and the arrival date is used for the gallery folder), and the answer is 200 `{id, offset: size, done: true}`. The hash is computed while the data arrives when the file went up in one run, so completing a multi-gigabyte file is not slow; after a resume across a restart the file is read once more.
- A chunk sent for a file that is already done answers its done state, so a phone whose last answer was lost can carry on.
- One chunk is written at a time per file. A newer request for the same file takes over from one still open (the phone has given up on that connection): the older one stops, keeping what it had written. If the takeover takes more than 5 seconds the newer one gets 409 `busy`.

`GET /v1/items/{id}` is how a phone resumes after a dropped connection or a restart of either side: `offset` is the length of what is on the computer. Bytes the computer had read when a connection broke count, bytes still on the wire do not, so the phone always continues from the offset it is told rather than from what it sent. A finished item's record stays for a day.

`POST /v1/gallery/check` takes `{ids}` and answers `{missing}`: the ids not yet received from this phone, in the order given, each once. A gallery sync sends the asset ids of everything on the phone in batches of up to 1000 and uploads only what comes back. Ids are kept per phone, so two phones with the same id do not interfere. The index outlives forgetting the phone, so pairing again does not send a gallery twice; the app can clear it for a full resend. A file that is still in progress is not in the index.

A refused chunk or item request's unread body is dropped up to 1 MiB before the connection closes; a phone that sends larger chunks blindly may see the connection reset instead of the answer, and then asks `GET /v1/items/{id}`. Sending `Expect: 100-continue` avoids it.

### Host to guest

The computer queues items per phone: text, a link, or a file reference with name, size and optional mime. The file stays where it is on the computer and is read when downloaded. At most 1000 items wait per phone, and the queue is kept on disk, so it survives a restart of the app.

`GET /v1/outbox?wait=<seconds>` answers `{items: [{id, kind, text?, url?, name?, size?, mime?}]}` with everything pending for the phone, oldest first. With nothing pending it waits up to `wait` seconds (0 if absent, 25 at most, more is cut to 25) and answers as soon as an item is queued, or empty when the time is up. A reply holds at most 100 items and at most 4 MiB of text and links together (always at least one item); when more is pending it carries `"more": true`, and the phone acknowledges what it got and asks again. The phone asks again straight away. An item stays in the list until it is acknowledged, so a phone must not treat one it already has as new.

`GET /v1/outbox/{id}/data` streams the file. Without `Range` the answer is 200 with the whole file; with `Range: bytes=<n>-` it is 206 with `Content-Range: bytes n-(size-1)/size` and the rest of the file, so a download resumes where it broke. Any other form of `Range`, or a start at or past the end of a file that is not empty, is 416 `rangeNotSatisfiable` with `Content-Range: bytes */size`; an empty file is always sent whole. A missing file is 404, and a file whose size no longer matches what was queued is 409 `changed`. Answers carry `Accept-Ranges: bytes` and the item's mime type, or `application/octet-stream`.

`DELETE /v1/outbox/{id}` acknowledges: the item is removed. It is 204 also when the item is gone already.

## Limits and timeouts

| What | Limit |
| --- | --- |
| Connections at once | 16, at most 6 from one address, more are closed at once |
| One request per connection | Every answer carries `Connection: close` |
| Request line, head | 2048 bytes, 16 KiB, 64 headers; CRLF only; `Host` required; HTTP/1.1 only; GET, PUT, POST, DELETE |
| Chunked encoding | Refused (any `Transfer-Encoding`, 501); a body needs one `Content-Length` |
| JSON body | 8192 bytes for pairing, 512 KiB for gallery check, 8 MiB for items (room for 1 MiB of text with every character escaped) |
| Text | 1 MiB UTF-8 |
| Chunk | 64 MiB |
| Free space | A file or chunk that would leave the drive under 1 GiB free is refused with 507 |
| Requests per address | 3000 a minute (429 with `Retry-After: 60`) |
| Failed secrets or tokens per address | 10 in a minute block the address; its connections are closed before TLS |
| TLS handshake | 10 seconds |
| Request line and headers | 10 seconds |
| Pairing body | 15 seconds in all |
| Any other body, and any answer | Idle-based: 30 seconds between two reads or two writes, with no limit on the total, so a multi-gigabyte upload over slow Wi-Fi is fine while it keeps moving |
| Long poll | `wait` up to 25 seconds; the connection is idle while it waits |
| Approval of a pairing | 120 seconds, then declined |
| Stopping | Requests being served get 2 seconds to finish, then are cut off |

An address counts as one peer whether it is written as IPv4 or as an IPv4-mapped IPv6 address.

## Storage on the computer

Files go to a receive folder the user can change; it defaults to `%USERPROFILE%\Downloads\Lazy Send`. Inside it each phone has a folder named after the phone (`<root>\<device name>\`), and files from a gallery sync, those with a `sourceId`, go to `<root>\<device name>\Gallery\YYYY-MM\` by their `modified` date in local time (the arrival date when it is absent). The folder is fixed when a transfer starts, so changing the receive folder later does not strand a transfer.

Names come from the phone and are made safe: path separators, characters Windows refuses and control characters become `_`, trailing dots and spaces go, a device name such as `NUL` or `COM1` gets `_` in front, and the name is cut to 240 UTF-8 bytes, keeping the extension. A name already taken gets ` (2)`, ` (3)` and so on before the extension. Every received file gets a `Zone.Identifier` stream with `ZoneId=3`, as a browser download does, so SmartScreen and Office checks apply to what a phone sends (an `.exe`, `.lnk` or `.url`). A file is written as `<id>.part` in its folder and renamed once complete; part files and their records older than 7 days are deleted at start.

| Path | Holds |
| --- | --- |
| `%APPDATA%\Lazy Send\devices.json` | The computer's id and the paired phones: id, name, platform, app version, the SHA-256 of the secret, paired and last-seen times. The secret itself is never stored |
| `%APPDATA%\Lazy Send\hosts.json` | The computers this one is a guest of: id, name, fingerprint, addresses, port, the address that answered last, and the secret as DPAPI protected it for the current Windows user (a guest has to present the secret, so unlike devices.json it cannot be a hash) |
| `%APPDATA%\Lazy Send\settings.json` | The receive folder |
| `%LOCALAPPDATA%\Lazy Send\history.json` | Received texts and links, newest first, at most 500 entries and 16 MiB of text |
| `%LOCALAPPDATA%\Lazy Send\incoming\<id>.json` | One record per file being received, or finished within the last day |
| `%LOCALAPPDATA%\Lazy Send\index\<phone id>.txt` | The source ids received from a phone, one per line, appended to as files arrive and read whole once per run |
| `%LOCALAPPDATA%\Lazy Send\index\usb-<hash>.txt` | The `<persistent id>:<size>` entries imported from a phone over USB (see Import over USB) |
| `%LOCALAPPDATA%\Lazy Send\usb-folders.json` | Which folder each phone on USB imports into, by the same device key as the index |
| `%LOCALAPPDATA%\Lazy Send\outbox.json` | What waits for the phones |

JSON files are written whole through a temporary file and renamed. A file that cannot be read is kept as `.bad` and replaced by an empty one.

## Storage on the iPhone

Received files go to the app's Documents folder, which shows in the Files app, with a name made safe and ` (2)`, ` (3)` on a clash; a download in progress is `<name>.part` until it is whole. Images and videos are also added to Photos when the user turns that on, and the assets the app added are remembered so a gallery sync does not send them back. The paired computers, the share queue and its files live in the App Group container `group.com.lazysend.lazysend`, shared with the share extension; each computer's secret and the phone's id are in the Keychain, this device only. Files the user picks to send are copied into the app's Application Support folder until they are sent, so a transfer can resume after the app is closed.

## The iPhone as a host

The iPhone app runs the server of `Sources/LazySendServer` while it is in front, so an Android phone or another iPhone can pair with it and send to it, and it sends to them, through the same routes a computer offers. Its Receive screen shows the QR code, the short code with the match digits, the check code, Copy link and Share link, and the approval prompt (120 seconds, declined when not answered), and says to keep the app open.

iOS suspends a listener that is not in front, so the server runs only while the app is active and either the Receive screen is open or a phone is paired, and it stops when the app goes to the background and starts again on return, with a new pairing code if the screen is open. A guest that polls an iPhone host while the app is closed fails to connect and keeps retrying, as it does for any host out of reach; what waits in the outbox stays there.

The phone's id as a host is the id it gives hosts as a guest (kept in the Keychain), and it is in the Bonjour TXT in the clear, as a computer's is, so a phone that is both a host and a guest of the same device keeps two lists, and the app shows two rows for it. The certificate is a permanent P-256 key and a self-signed certificate in the Keychain (tag `com.lazysend.identity`, this device only, usable after the first unlock), renewed on the same key 60 days before it ends. The fingerprint is kept in `Host/fingerprint.txt`; when it differs at launch (a backup restored on another phone, where the key did not come along) the pairings and the outbox are dropped and guests pair again. `_lazysend._tcp` is registered with the DNS-SD API while the server listens, on Wi-Fi, wired and hotspot interfaces only (the listener refuses the mobile network and the pairing code lists no cellular address), with the TXT keys `v`, `id` (the phone's id) and `n` (the phone's name).

The paired phones, `outbox.json`, `history.json`, `incoming/` and `index/` are in `Host/` of the App Group container, under the names the computers use; secrets are kept as hashes, as for a computer. Files from a guest go to the app's Documents folder in a folder named after the guest (`<Documents>/<device name>/`), gallery files to `<Documents>/<device name>/Gallery/YYYY-MM/`, with the names made safe as on the Mac and no quarantine attribute (iOS has none), and are also added to Photos when the user turned that on, which the gallery sync knows about as it does for files from a computer. Texts and links go into the app's received list. The 1 GiB free-space floor holds, counted with the space the system can clear. A file queued for a guest, picked in the app or left by the share sheet, is copied into `Host/Outgoing/<id>/` at once (a picked photo is moved) and the copy is deleted when the guest has acknowledged the item or is removed; the share sheet lists a guest phone next to the computers and only leaves the item for the app, since a phone is reached only while the app is open.

## Android as a host

The Android app runs the same server as the other hosts, written in Kotlin on a plain TLS server socket (no HTTP library, since the rules above, one request per connection and no chunked bodies, are a small subset of HTTP/1.1). It is started by the Receive screen, which shows the QR code, the short code with the match digits, the check code, Copy link and Share link, and the approval prompt: Allow and Don't allow are the only ways to answer, and leaving the screen or the app declines what waits (120 seconds otherwise, as everywhere).

The phone's id as a host is the id it gives hosts as a guest, and it is in the DNS-SD TXT in the clear (`v`, `id`, `n`), registered through NsdManager while the server listens, so a phone that is both a host and a guest of the same device keeps two lists and shows two rows. The certificate is a permanent P-256 key in the Android Keystore, which never leaves it, with a self-signed certificate renewed on the same key 60 days before it ends. The key's fingerprint is kept in `host/fingerprint.txt`; when it differs at start (the Keystore key did not come along with a restore) the pairings and the outbox are dropped and guests pair again.

The server listens on one port (52734, any free port when taken) but answers only connections that arrive on Wi-Fi, Ethernet, USB tethering, Wi-Fi Direct or hotspot interfaces (`wlan`, `wifi`, `p2p`, `ap`, `swlan`, `softap`, `rndis`, `usb`, `ncm`, `eth`) from loopback, private, link-local and unique-local peers or the subnet of one of those interfaces; anything else, a mobile network (`rmnet`, `ccmni`) included, is closed before TLS. The pairing code lists only those interfaces' addresses, IPv4 first and 169.254.x.x last. A listener that fails is started again after 1 second, doubling to 30.

While the Receive screen is open the server runs in the app; when a guest is paired it keeps running in the foreground service (type dataSync, ongoing notification "Receiving on Wi-Fi" with Stop) until the person stops it. Leaving the screen with no guest paired stops it. Android 15 limits a dataSync service to six hours a day; when the system times it out the host stops.

Files from a guest go to `Download/Lazy Send/<device name>/` through the media store (photos to `Pictures/Lazy Send/<device name>/`, videos to `Movies/Lazy Send/<device name>/`), gallery files to `<device name>/Gallery/YYYY-MM/` by the date taken, as pending media-store entries until whole, so a part resumes across a restart; before Android 10 they are `.part` files in the same folders. The media store renames a clash itself (`name (1).jpg`). The 1 GiB floor is counted on what the storage manager reports as allocatable, which includes space the system can clear. Texts and links go into the received timeline. State is in `files/host/` (`guests.json`, `outbox.json`, `incoming/`, `index/`, `outgoing/`). A file queued for a guest, picked or shared, is copied into `outgoing/` at once and the copy is deleted when the guest has acknowledged the item or is removed. The share sheet lists the guests next to the computers.

A used or expired pairing session answers `pairingClosed`, since the host has no session to show by then. A `Range` that is not `bytes=n-` gets 416 with `Content-Range: bytes */size` like the other 416 answers.

## Storage on the Mac

The Mac app is sandboxed (Mac App Store, bundle id `com.lazysend.lazysend`, on the iPhone app's App Store record). Settings and state are in the app's container, `~/Library/Containers/com.lazysend.lazysend/Data/Library/Application Support/Lazy Send/`, under the same names as the Windows state folder: `devices.json`, `settings.json`, `history.json`, `incoming/`, `index/` and `outbox.json`. Received files go to `~/Downloads/Lazy Send` by default (the Downloads entitlement, since the sandbox's own `~` is the container), laid out as in Storage. A receive folder the user picks is kept as a security-scoped bookmark next to its path in `settings.json`, so it opens again after a restart; a transfer's folder is fixed when it starts, as on Windows.

Names are made safe for macOS: `/`, `\` and `:` and control characters become `_`, leading and trailing dots and spaces go, and the name is cut to 240 UTF-8 bytes keeping the extension. Every received file gets the `com.apple.quarantine` attribute, as a browser download does, so Gatekeeper checks what a phone sends (an app, a script). The file's modified time is set from `modified`.

As a guest, the Mac keeps the computers it is paired with in `hosts.json` next to `devices.json` (id, name, fingerprint, addresses, port and the address that answered last), and each one's secret as a generic password in the login keychain (service `com.lazysend.hosts`, account the host's id), since a guest has to present the secret. The Mac's own computer id is the id it gives them. What a host sends is stored like what a phone sends, in `<receive root>/<host name>/`, with the same name rules and the `com.apple.quarantine` attribute, and its texts and links go into `history.json`. The Info.plist lists `_lazysend._tcp` under `NSBonjourServices` and explains the local network use in `NSLocalNetworkUsageDescription`, so browsing for computers works in the sandbox.

The certificate is a permanent P-256 key and a self-signed certificate in the login keychain (tag `com.lazysend.identity`); phones pin the key, so the certificate is renewed on the same key 60 days before it ends. The phones' secrets are never kept on the Mac, only their hashes in `devices.json`. A file queued for a phone stays where it is and is opened again after a restart through a security-scoped bookmark kept with the queue entry.

The server is one `NWListener` on port 52734 (any free port when taken) for every interface, with the limits above. `_lazysend._tcp` is registered with the DNS-SD API on all interfaces. A phone with Personal Hotspot over a cable shows up as a network interface, and its address is in the pairing code and in `hello` like a Wi-Fi address. Android USB tethering needs a driver that current macOS no longer has, so an Android phone on a cable cannot reach the Mac; it pairs over Wi-Fi or a hotspot.

## Import over USB (Windows)

A phone plugged in by cable is read without the phone app: Windows lists an iPhone (with Apple's driver, from Apple Devices or iTunes, unlocked and trusted) or an Android phone in File transfer mode as a portable device. The app reads `DCIM` on every storage, and `Pictures\Screenshots`, takes photo and video files by extension and skips names starting with a dot.

Files go where the phone app's gallery files go: `<root>\<folder>\Gallery\YYYY-MM\`, the month from the file's modified date (created date when absent) in local time. Windows lists every iPhone as "Apple iPhone", so the folder is not simply the USB name. It is the name of a paired phone: when exactly one paired phone is of the same kind (iPhone or Android, from the pairing's platform) it is used and remembered; when several are, the app asks once which one this is, with "none of these" as an answer; when none is, the USB name is used, with a short id from the device key after it when another USB device already has that name. A name from the USB device is looked at again when a phone of its kind is paired later, unless the user chose it. The answers are kept in `usb-folders.json`, by device key, and a paired phone is followed through a rename. Each file is written as a `.part` file and renamed, gets the `Zone.Identifier` stream and its modified time, and takes ` (2)`, ` (3)` on a name clash.

An item is skipped when the phone's index already holds `<persistent id>:<size>`, or when the month folder already holds a file of the same cleaned name and the same size (a photo the phone app sent over Wi-Fi; it is added to the index then). The device key is `usb-<hash>` and the index is `index\usb-<hash>.txt`, one entry per line, where the hash is the first 32 hex digits of the SHA-256 of the portable device's id, which carries the phone's serial. The persistent id is the portable device object's `WPD_OBJECT_PERSISTENT_UNIQUE_ID` and the size is the one listed, even when the phone sends another (Apple converts HEIC on the fly unless Settings > Photos > Transfer to Mac or PC is set to Keep Originals).

An item is added to the index once its file is in place, so Stop, a failed item or an unplugged phone leaves the finished files and a later run copies the rest. A file cut off in the middle starts again from its first byte. A file the phone cannot read is counted and passed over; a phone that is gone ends the run as disconnected; a full disk or a refused folder ends it as failed.

## What the Windows app provides

The core runs without a screen. The app adds the certificate (made once with `SelfSignedCertificate.Create` and kept under the user's account), the DNS-SD advertisement for `_lazysend._tcp` with the TXT keys above, the approval prompt (`LinkRouter.ApprovePairing`), the QR code, the firewall rule check and the windows. It starts the server while a phone is paired or a code is shown, and refreshes the addresses in the code when the network changes.

The Store build keeps its certificate and its pairings per package, apart from the direct build's, so moving between the two builds or reinstalling means pairing phones again.

## A computer as a guest

A Windows or Mac computer pairs with another computer as a phone does, with `platform` `windows` or `mac`, its own computer id as `phoneId` and its name as `phoneName`; the wire names stay as they are. Connect to a computer browses `_lazysend._tcp` and lists what answers by its `n` (the instance name when a host sends none, then "Computer"), leaving out its own `id`. The user picks one and types the short code, or pastes a pairing link, and sees the match code while the host's user answers. With a link the connection is pinned to the link's key from the start. With a short code the key is the one met on the first `health` answer, the guest shows the match code and asks before it sends anything, and `POST /v1/pair` goes over a connection pinned to that key; answering no ends it with the code unused.

The app tries a host's addresses in turn, the one that answered last first, and checks each with `hello` over TLS pinned to the host's key. The addresses in `hello` go in front of the kept ones (at most 8 in all, anything that is not an IP address or carries a zone dropped), the address that answered is remembered with its port, and when none answers the address and port the host announces on the network are tried. A host that answers 401 has forgotten this computer and is dropped here, unless the secret it refused is no longer the one kept (pairing again replaced it, and the watch and the sends in flight start over with the new one); a secret that cannot be read here is not a reason to drop it, the host stays listed and unreachable until the user connects to it again. At most 16 hosts are kept.

While the app runs it keeps `GET /v1/outbox?wait=25` open for each host and takes the items as a phone does. Texts and links go into the received history under the item's own id, so a repeat is noticed. A file is written as `<id>.part` in `<receive root>/<host name>/`, continued with `Range` after a drop, renamed when whole, marked as downloaded (see Storage) and then acknowledged. An item whose id is not a plain id is refused, as the id names the part file. A receive folder that cannot be used (missing, denied, on a drive that is not there) leaves the item queued and is tried again, and the user is told once. A file listed again after its acknowledgement was lost is only acknowledged, as the app keeps the ids of the 200 files it finished last for each host. Part files of a host that was removed or dropped an item are deleted, and so are part files of a day or more that no listed item continues. A host out of reach is tried again after 5 seconds, then at doubling gaps up to 60, and an answer this app cannot read is treated the same way. What this computer sends goes up through the same routes a phone uses, files in 4 MiB chunks, continuing from the offset the host gives after a drop.

## Hand-off from other apps (Windows and Mac)

Another app sends files to the selected phone by opening `lazysend:open?file=<path>`, the `file` parameter repeated for each file and each path absolute and percent-encoded. The Windows app registers the address (the manifest in the Store build, `HKCU\Software\Classes\lazysend` in the direct build, with the argument quoted) and treats the files as it treats paths given on its command line: a running instance takes them over its single-instance pipe, and with no phone to send to the window opens to say so. Any other `lazysend:` form is ignored; pairing addresses are read by phones, never by the PC.


The Mac app registers the `lazysend` scheme in its Info.plist and takes the addresses and the files of Open With and the Dock icon alike, through the same path as files picked in its window. A sandboxed app cannot read a bare path that another app names, so a path outside what the sandbox opens for it is reported as unreadable and not sent; an app that hands files over should open them with Lazy Send (as `NSWorkspace` does) and not rely on the address.

## What the Mac app provides

`Sources/LazySendServer` is the same core as the Windows one, in Swift on the Network framework, and the tests in `Tests/LazySendServerTests` run the phone client of `LazySendKit` against it over loopback. The app adds the keychain identity, the DNS-SD registration, the approval prompt, the QR code (Core Image), the notifications, the menu bar item and the windows. It starts the server while a phone is paired, a code is shown or a phone waits for an answer, and refreshes the addresses in the code while the pairing sheet is open. The pairing sheet shows the short code with the digits the other computer then shows, and a Copy link button; the approval prompt shows the digits of the way the pairing came in. As a guest (`GuestService` in the server module, with the Connect to a computer window in the app) the Mac pairs, sends and collects through the same `LazySendKit` client the iPhone app uses, and lists the computers it is connected to among the phones, each row under an id of its own so a machine paired both ways has two.
