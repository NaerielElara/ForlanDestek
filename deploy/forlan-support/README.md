# Forlan Destek API

The support API, administrator page, and data live on the same Docker host as the RustDesk rendezvous/relay services. The administrator page is available only from that PC; customer applications reach the API over HTTPS at the host's static IP. No DNS record or Forlan Yazılım domain is needed for account or license management.

## First launch

1. Forward TCP **24443** on the router to this Docker host. The support API does not require public ports 80 or 443. Keep the existing RustDesk port forwards unchanged. The public API uses `https://95.70.196.174:24443` by default.
2. From PowerShell, run `powershell -ExecutionPolicy Bypass -File .\start-support.ps1`. This creates random database/JWT/admin credentials on the first launch, protects their local files, starts the support stack and verifies the administrator account. Sign-in details are stored in `admin-access.txt`; do not upload or share that file.
3. The connection server and support stack are separate Docker projects. To manage them independently from this directory:

   ```powershell
   docker compose -f ..\forlan-server\compose.yaml up -d
   docker compose --env-file .\.env -f .\compose.yaml ps
   docker compose --env-file .\.env -f .\compose.yaml logs --tail 50 support-api support-proxy
   ```

4. Open the administrator page on the server PC at `http://127.0.0.1:18080/admin/`. The startup script checks `/healthz` and removes the bootstrap credentials from `.env` after validating the first administrator, then recreates only the API container. If you configure `.env` manually, do the same after the first start:

   ```powershell
   docker compose --env-file .\.env -f .\compose.yaml up -d --no-deps --force-recreate support-api
   ```

The admin page must be opened through this local HTTP address, not by double-clicking the `index.html` file: the page calls the API using same-origin `/api/...` paths. The API's host port is bound to `127.0.0.1`, and Caddy returns 404 for `/admin/` on the public IP, so the admin interface is not exposed to the internet. Database and API containers remain on the same PC.

Caddy generates and renews the IP certificate using its own private certificate authority. `start-support.ps1` exports only the public CA certificate to `support-ca.crt`; the private signing key stays in `forlan_caddy_data`. The Windows build embeds that public certificate so the app validates the server certificate and IP address without disabling TLS checks or installing a system-wide root certificate. Ordinary browsers will not trust the public API certificate by default; use the localhost address to administer the service.

Run the startup script before building. `build.py` reads `support-ca.crt` and sets `FORLAN_SUPPORT_CA_BASE64` automatically. For a different certificate location, set `FORLAN_SUPPORT_CA_PATH` to its absolute path. If the server IP changes, update `FORLAN_SUPPORT_HOST` in `.env` and rebuild the app with `FORLAN_SUPPORT_API_URL` set to the new HTTPS IP and port.

The desktop build uses `https://95.70.196.174:24443` for the support API by default. The **Lisans satın al** button still opens `https://forlanyazilim.com/iletisim/`; this link is only for purchase inquiries and is not used to store or administer accounts or licenses.

## Current API

- `POST /api/auth/login`, `GET /api/me`
- `POST /api/admin/accounts`, `GET /api/admin/accounts`
- `POST /api/admin/licenses`, `POST /api/admin/licenses/{id}/revoke`
- `POST /api/tickets`, `GET /api/tickets`, `GET /api/tickets/{id}`
- `POST /api/tickets/{id}/messages`, `PATCH /api/tickets/{id}/status`
- `GET /api/events?after=<cursor>` (authenticated support notifications)
- `POST /api/tickets/{id}/connection-request` (staff, active customer license, open ticket)

Administrators and technicians see the shared ticket pool. Customers need a valid license with support included to create tickets and can only read their own active tickets. Role, license entitlement and ownership checks run in the API for every request. Account passwords are Argon2 hashes; session tokens expire; login attempts are throttled; privileged changes are recorded in the audit table.

New support tickets are restricted by the API to the `Yazılım` and `Sistem` categories. Administrators can activate/disable accounts and revoke licenses from the administrator page.

## Desktop support notifications (1.16.0+)

Customers and technicians sign in using **Giriş yap / Lisansı etkinleştir** in the service footer. Support controls are hidden for guests and usage-only licenses. Hiding the main window keeps the in-memory session and polling active. Usage-only sessions poll their license profile without requesting tickets or support events. Signing out, quitting, or expiry of the session token ends notification delivery until the next sign-in. Credentials are not saved to disk.

New licensed customer tickets notify the shared staff pool; incoming messages notify the other participants. Windows notifications are dismissible and hidden after approximately 15 seconds. Windows notification settings and Do not disturb can suppress banners. The supplied message sound is bundled with the application.

New desktop tickets include the activated device ID. Staff can use **Bağlan** inside an open ticket to send a silent connection notification and start the normal remote connection. The connection sound and its asset have been removed. New tickets, incoming messages, technician notifications and ticket status notifications use the message sound; **Ayarlar → Genel → Destek bildirimleri** can disable it. Existing remote password/approval checks still apply.

## License codes and ticket ownership (1.14.0+)

In the administrator page, enter a company name and duration (days) to create a customer and random license code. Select an existing company to add another license. Codes remain visible and copyable in the license list; they are encrypted in the database. Customers sign in with their code only. Staff accounts retain their personal username and password.

Renew extends a license, rotate generates a replacement code and invalidates the previous code and its sessions. Archive hides an account or license from daily use; restore returns it. Permanent deletion requires the company/account name. Customer deletion also removes that customer's tickets and licenses; deleting a technician returns their assigned tickets to the pool and preserves their name on old messages and audit records. The last administrator cannot be removed.

The desktop **Destek** tab shows customers their active tickets and conversations. Staff have Active/Archive lists and operation history. Connecting from a ticket assigns it to that technician atomically. Its owner can release it or use **Teknisyene bildir** to send a required note only to the selected technician; notification does not change ownership. Another technician cannot change or connect through the assigned ticket; administrators can intervene. Cancellation also requires a note. License reminders appear during the final 14 days.

## License plans and devices (1.16.0+)

New licenses default to usage-only and one device. Select **Forlan müşterimiz — destek hizmeti dahil** for customers entitled to ticket support. A trial requires 1–90 days; the panel defaults to seven days. Support entitlement belongs to the exact license code, so another code for the same company does not grant support access. Staff accounts always have support access.

The **Haklar** action changes support entitlement and device count. Zero means unlimited devices. Existing licenses migrate to support included/unlimited devices to preserve their previous access. Use **Cihazlar** to inspect device name, remote ID, app version and first/last seen time. Removing a device frees its slot and invalidates its sessions; it cannot sign in again until explicitly restored. Restoring does not revive old session tokens. Lowering a positive device cap below the current active count is rejected; remove devices first. Device access changes are recorded in the audit history.

New clients register a device even on unlimited licenses. For compatibility, older clients without device metadata may keep using unlimited licenses, but are absent from inventory and cannot be revoked individually; code revocation still works. A positive device cap requires an updated client and device-bound authentication. These identifiers are application device identities, not hardware attestation.

## Outgoing connection policy (1.16.0+)

The updated Windows client requests signed permits from `/api/connections/start`. Free initiators can start one connection for five minutes, then wait one minute. Each free connection allows 30 MiB of outgoing file content (displayed as 30 MB), shared across file manager and Windows file copy/paste. Text clipboard and incoming files do not consume it. File-manager child channels share the remote connection's signed policy, deadline and quota; reopening them does not reset the allowance. Selections are prechecked where size metadata is available and each actual outgoing block is checked before sending. Retries consume actual repeated file bytes; resumed jobs do not reset the counter.

Valid licensed sessions, including usage-only licenses, and staff can start multiple connections without these duration/file quotas. Their connections are unlimited in both file directions even when the recipient has no license. The authenticated identity is fixed for an active connection; activating another license applies to new connections, so reconnect to replace an existing free connection. Receiving a connection is not subject to the initiator's free-use limit.

Permits are signed with Ed25519, bound to the session, device and peer IDs, and validated by the Windows core. They are refreshed every 30 seconds and expire after at most 90 seconds without renewal. Starting a connection requires API access. The server retains free-session deadlines and cooldowns across client restarts. These controls apply to the new official client: older executables and modified clients are not restricted by the stock RustDesk signaling server. This is not a tamper-proof signaling-server license enforcement system.

`build.py` obtains the public signing key using validated HTTPS and caches it in `policy-public-key.json`. The signing key and license encryption key are independently derived from `JWT_SECRET`. Keep this secret stable and backed up with the database: changing it without migrating licenses makes stored license codes unreadable and invalidates deployed clients' signing-key trust. Never publish `.env`, database dumps or `admin-access.txt`.

Back up the `forlan_support_data` and `forlan_caddy_data` Docker volumes. Never remove them when updating containers: replacing the CA volume would invalidate existing applications' embedded server trust and require new client builds. Keep a protected backup of `.env` and the administrator credentials as well.
