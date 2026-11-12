# Lazy Send contracts

Lazy Send moves text, links, files and whole photo galleries between a computer and a phone, in both directions. This file is the protocol and the rules both sides keep. The Windows core is C# in `windows/LazySend.Core/Link`; the phone apps, the Mac app and the Windows app are not written yet and will follow this file.

The phone link is Lazy Print's (its CONTRACTS.md, "The phone link"), copied and changed: the same TLS server, pinning, pairing and limits, with the print package and the sync folder left out and uploads, a gallery index and a computer-to-phone outbox added. The apps do not share pairings, ports or files with any other Lazy app.

## Identifiers

| Thing | Value |
| --- | --- |
| Name in text, in code | Lazy Send, LazySend |
| Namespace (Windows core) | `LazySend.Core` |
| Protocol version | 1, in the pairing code and every hello, health and pair answer |
| Pairing code | `lazysend://pair?v=1&id=&n=&fp=&a=&p=&t=` |
| DNS-SD service | `_lazysend._tcp`, TXT keys `v` (protocol version) and `id` (the computer's id) |
| Port | 52734 first (Lazy Scan 52731, Lazy Print 52732, Lazy PDF 52733), any free port when taken |
| `service` in health answers | `lazysend` |
| Settings | `%APPDATA%\Lazy Send\devices.json`, `settings.json` |
| State | `%LOCALAPPDATA%\Lazy Send\` (see Storage) |

Ids (a computer's, a phone's, an item's) are 8 to 64 characters from letters, digits, `-` and `_`, so they are safe as file names. The server makes item ids as 32 hex digits.

## Pairing

The computer is the server and the phone is the client, always: the phone opens every connection, and the computer never connects out. The connection is HTTP/1.1 over TLS 1.2 or 1.3 with the computer's own certificate, self-signed ECDSA P-256. The phone does not trust a certificate authority; it trusts the one key whose fingerprint came in the pairing code, the SHA-256 of the certificate's SubjectPublicKeyInfo (so a renewed certificate on the same key keeps every pin).

The code the computer shows as a QR is the URI above. `v` is the protocol version, `id` the computer's id, `n` its name, `fp` the fingerprint as base64url without padding (43 characters), `a` a comma-separated list of its addresses (each percent-encoded, at most 8, IPv4 first), `p` the port and `t` the pairing token, base64url of 16 random bytes. Values are percent-encoded UTF-8; unknown parameters are ignored so later versions can add some. A code with a higher `v` than the app speaks is refused with a message to update.

The addresses are those of every interface that is up, whatever its type, loopback and IPv6 link-local ones left out. USB networking is not special: an iPhone's Personal Hotspot over USB gives the computer an address such as 172.20.10.x and Android USB tethering usually 192.168.42.x, and both are in the list like a Wi-Fi address. Self-assigned 169.254.x.x addresses go last. The phone tries the addresses in turn and checks the fingerprint on whichever answers. `hello` lists the same addresses as they are at that moment, so a phone paired over Wi-Fi learns the computer's USB tether address once it has reached it any way at all, and keeps the list up to date.

The server listens on every interface, IPv4 and IPv6, on one port. It answers only peers from loopback, private, link-local and unique-local addresses, or from the subnet of one of the computer's own addresses (which is how a 100.64.0.0/10 address, as Tailscale uses, gets in); anything else is closed before TLS starts.

1. The user opens pairing on the computer. A session starts: a random token, good for 5 minutes and for one pairing.
2. The phone scans the code and sends `POST /v1/pair` with the token and who it is.
3. The computer checks the token, then asks the user on screen whether this phone may pair. Without an answer within 120 seconds the pairing is declined, and the default answer when nothing is wired to answer is decline.
4. On approval the computer makes a 32-byte secret for the phone, stores only its SHA-256, and answers with the secret once. The phone counts as paired only once the answer has been written to it; when the write fails the phone is forgotten again.
5. Every later request carries `X-Device-Id: <phone id>` and `Authorization: Bearer <secret>` (the secret as base64url). A wrong id or secret gets 401 and counts as a failure.

Tokens are compared in constant time. Five wrong tokens from one address refuse that address for the rest of the session and 25 from all addresses together close the session. A closed, used or expired session answers `pairingClosed`. At most 16 phones can be paired; the answer for a 17th is 409 `tooManyDevices`. Pairing again with the same phone id replaces its entry and secret. Pairings are not shared with the other Lazy apps.

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

### Phone to computer

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

### Computer to phone

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
| `%APPDATA%\Lazy Send\settings.json` | The receive folder |
| `%LOCALAPPDATA%\Lazy Send\history.json` | Received texts and links, newest first, at most 500 entries and 16 MiB of text |
| `%LOCALAPPDATA%\Lazy Send\incoming\<id>.json` | One record per file being received, or finished within the last day |
| `%LOCALAPPDATA%\Lazy Send\index\<phone id>.txt` | The source ids received from a phone, one per line, appended to as files arrive and read whole once per run |
| `%LOCALAPPDATA%\Lazy Send\outbox.json` | What waits for the phones |

JSON files are written whole through a temporary file and renamed. A file that cannot be read is kept as `.bad` and replaced by an empty one.

## What the Windows app provides

The core runs without a screen. The app adds the certificate (made once with `SelfSignedCertificate.Create` and kept under the user's account), the DNS-SD advertisement for `_lazysend._tcp` with the TXT keys above, the approval prompt (`LinkRouter.ApprovePairing`), the QR code, the firewall rule check and the windows. It starts the server while a phone is paired or a code is shown, and refreshes the addresses in the code when the network changes.
