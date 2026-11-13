# Obsidian LiveSync

Tailnet-only CouchDB that the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin replicates an Obsidian vault to. It replaces Syncthing for the vault; `apps/syncthing` still serves its other folders.

- App: `apps/livesync` (Argo CD `Application` `livesync`, namespace `livesync`)
- URL: `https://livesync.beaver-cloud.ts.net` (confirm the exact name with `kubectl -n livesync get ingress livesync-ingress`)
- Database: `obsidiannotes`
- Storage: 10Gi `zfs-generic-nvmeof-csi` zvol on drone-04

There is no public listener. The phone must have the Tailscale app connected, and Obsidian only syncs while it is in the foreground on iOS.

## Credentials

The admin and vault credentials exist only in the seeded `livesync-credentials` Secret:

```sh
kubectl -n livesync get secret livesync-credentials -o jsonpath='{.data.vault-user}' | base64 -d; echo
kubectl -n livesync get secret livesync-credentials -o jsonpath='{.data.vault-password}' | base64 -d; echo
```

Clients use the **vault** user, never the admin user. The admin user is only for maintenance and for the pod's own startup bootstrap.

To rotate either password, update the plaintext locally, re-seal it into `apps/livesync/credentials-sealed-secret.yml` (follow `docs/secrets.md`), commit, and restart the pod: the entrypoint re-seeds the admin password and the `postStart` hook upserts the vault user.

## Bring-up order

Do this in order; the first sync is the only step that is hard to undo.

1. **Rehearsal vault first.** Create a throwaway vault on the desktop, not the real one. This proves TLS, auth, CORS, and the ingress path while nothing is at stake.
2. In Obsidian: install **Self-hosted LiveSync** from Community Plugins, then open its settings and use **Setup Wizard** / manual connection with:
   - URI: `https://livesync.beaver-cloud.ts.net`
   - Username / password: the vault user from above
   - Database name: `obsidiannotes`
   - E2EE passphrase: **set one before the first sync** (see below)

   When the wizard asks how to set up, choose the **Join / Fetch** path, never Rebuild (see below).
3. Write a test note, wait for the status bar to settle, then delete the pod and confirm the note comes back.
4. On iOS: install Obsidian and the plugin, connect Tailscale, and join using the **Setup URI** from the desktop (`Copy settings as a new Setup URI`). Verify a phone note reaches the desktop, and an offline edit syncs after reconnecting.
5. Once both directions work, repeat with the real vault, and remove the Obsidian vault from Syncthing on every device.

## Setup path: Join, not Rebuild

The vault user is deliberately **not** a CouchDB server admin, so the plugin's **Rebuild** path fails with `401 You are not a server admin`: Rebuild deletes and recreates the remote database, and CouchDB only lets a server admin delete a database. This is by design upstream ([vrtmrz/obsidian-livesync#1286](https://github.com/vrtmrz/obsidian-livesync/issues/1286)). The database already exists, so always join it:

1. Cancel any pending rebuild (or close the dialog) and restart onboarding.
2. Import the Setup URI and choose **Join this device**; in the onboarding question that is "I am adding a device to an existing synchronisation setup".
3. On the Fetch prompt choose **Compare time and take newer**, then **Keep local files even if deleted on remote**.
4. If **No Synchronisation Settings Found** appears, choose **Use this device's settings**.

Fetching connects without deleting anything; local notes then upload through normal synchronisation. After the first device is connected, generate further Setup URIs from that device rather than from the generator script.

## End-to-end encryption

Enable E2EE in the plugin **before the first sync**. Enabling it later means re-uploading the vault.

With E2EE on, the CouchDB volume and every ZFS snapshot contain only ciphertext, so:

- store the passphrase and the Setup URI in a password manager, outside the cluster;
- the recovery path for a lost server is "any device that still has the vault", not a backup on the NAS;
- do not set a passphrase you cannot recover: there is no server-side way to read the data without it.

## `.obsidian` configuration

Syncthing used to carry the whole `.obsidian` directory for free. LiveSync does not sync hidden files by default:

- Prefer **Customisation Sync** (advanced settings) with plugins, snippets, themes, and hotkeys selected explicitly.
- Avoid full **Hidden File Sync**: it also syncs `workspace.json`, so the phone and desktop continually fight over window layout.

Enable either one only after basic note sync is verified.

## Operations

```sh
# health of the pod and volume
kubectl -n livesync get pods,pvc

# unauthenticated request must be 401, and the CORS origin must be echoed
curl -s -o /dev/null -w '%{http_code}\n' https://livesync.beaver-cloud.ts.net/
curl -sI -H 'Origin: capacitor://localhost' https://livesync.beaver-cloud.ts.net/ | grep -i access-control

# restart (Recreate, single replica, RWO volume)
kubectl -n livesync rollout restart deploy/livesync-app-deployment
```

- Compaction runs automatically when a database passes 50% fragmentation (`[compactions] _default` in `zz-livesync.ini`). Manual `POST /obsidiannotes/_compact` with admin credentials remains available.
- Watch PVC usage occasionally; revision history, not note size, is what grows.
- A drone-04 reboot stops the pod; the reboot playbook scales it down and back up, and clients queue changes locally in the meantime.
- Configuration lives in `apps/livesync/zz-livesync.ini`. Changes made through the admin API at runtime are discarded on restart by design.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Desktop syncs, phone fails | CORS must allow `capacitor://localhost`; also try the plugin's **Use Request API** setting |
| Phone never connects | Tailscale must be connected on the phone; the plugin status bar shows "stopped" otherwise |
| 401 from `curl` but clients work | Expected: authentication is mandatory, and an unauthenticated `/` is the health signal Gatus uses |
| Setup fails with `401 You are not a server admin` | The plugin chose the Rebuild path; cancel it and join the existing database instead (see "Setup path" above) |
| Pod crash-loops on start | `kubectl -n livesync logs deploy/livesync-app-deployment -c config-init` and the main container logs; the entrypoint needs a writable `/opt/couchdb/etc` |
| Gatus reports unhealthy while CouchDB runs | An unauthenticated request returned something other than 401, meaning `require_valid_user` was not applied |

## Rollback

Delete the Argo CD `Application` and the namespace, or scale the deployment to 0. With E2EE on, every connected device still holds a full copy of the vault; without it, take a CouchDB dump or a ZFS snapshot of the volume first.

```sh
kubectl -n argocd delete application livesync
kubectl delete namespace livesync
```

Nothing else in the cluster depends on this app.
