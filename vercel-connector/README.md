# ontacoche vercel connector

Serverless webhook connector to deliver Flespi events to Firebase Cloud Messaging.

## flow

`tracker -> flespi -> vercel -> firebase -> app`

Current behavior:

- incoming stream or platform webhook events are classified in the webhook.
- report `0200` updates current device state in Firestore (`device_last_state`) and can be appended to history.
- push notifications are sent only for alert-like events (vibration/geofence by default).
- regular active communication (`0200` without alarms) is persisted but not pushed unless explicitly enabled.

## endpoint

- `POST /api/flespi-webhook`
- required header: `Authorization: Bearer <WEBHOOK_BEARER_SECRET>`
- required content type: `application/json`
- payload must include at least one routing field: `device_id` or `user_id`

Token registration endpoint:

- `POST /api/register-token`
- required header: `Authorization: Bearer <FCM_TOKEN_SYNC_BEARER>`
- required content type: `application/json`
- payload must include `token` plus `device_id` or `user_id`

Geofence CRUD endpoints (phase 1 circles):

- `GET /api/geofences?device_id=<ident>`
- `POST /api/geofences`
- `PATCH /api/geofences/:id`
- `DELETE /api/geofences/:id`
- `POST /api/geofences/:id/assign-device`
- required header: `Authorization: Bearer <APP_WRITE_BEARER>`

## required environment variables

- `WEBHOOK_BEARER_SECRET`: shared secret used by Flespi webhook authorization header.
- `FCM_TOKEN_SYNC_BEARER`: shared secret used by the mobile app when syncing FCM tokens.
- `FIREBASE_PROJECT_ID`: Firebase project id.
- `FIREBASE_CLIENT_EMAIL`: service account client email.
- `FIREBASE_PRIVATE_KEY`: service account private key (escaped newlines are supported).

## optional environment variables

- `FCM_TOKEN_COLLECTION`: Firestore collection name. default: `fcm_tokens`
- `DEFAULT_DEVICE_ID`: fallback routing key when incoming event has no `device_id`/`user_id` (useful for single-device stream setup)
- `DEVICE_STATE_COLLECTION`: latest per-device state collection. default: `device_last_state`
- `STATE_HISTORY_COLLECTION`: state history collection (for 0200 snapshots). default: `device_state_history`
- `ALERTS_COLLECTION`: alert records collection. default: `device_alerts`
- `STORE_STATE_HISTORY`: enable or disable storing 0200 history snapshots. default: `true`
- `PUSH_ON_COMMUNICATION_ACTIVE`: send push for plain 0200 communication events. default: `false`
- `LOG_LEVEL`: not enforced yet, default: `info`
- `APP_WRITE_BEARER`: bearer used by app for geofence write/list endpoints
- `FLESPI_TOKEN`: server-side flespi token used by geofence CRUD handlers
- `FLESPI_GEOFENCE_CALC_ID`: calculator id that must include all managed geofences
- `FLESPI_BASE_URL`: optional, defaults to `https://flespi.io`

## firestore token model

Collection: `fcm_tokens`

Recommended document shape:

```json
{
  "token": "fcm_registration_token",
  "device_id": "123456",
  "user_id": "user_42",
  "active": true,
  "platform": "android",
  "updated_at": "2026-03-22T00:00:00.000Z"
}
```

Notes:
- the webhook queries active tokens by `device_id` and/or `user_id`.
- when Firebase returns `messaging/invalid-registration-token` or `messaging/registration-token-not-registered`, the token is marked as inactive.

## local run (optional)

This project is designed for Vercel serverless runtime. You can still validate syntax locally:

```bash
npm install
npm run check
```

## app integration env vars (.env in Flutter app)

- `VERCEL_CONNECTOR_URL`: base URL for connector APIs, example `https://ontacoche.vercel.app`
- `VERCEL_CONNECTOR_READ_BEARER`: optional bearer for `GET /api/device-state` if `APP_READ_BEARER` is set in Vercel
- `VERCEL_CONNECTOR_WRITE_BEARER`: bearer for geofence CRUD endpoints (`APP_WRITE_BEARER` on Vercel)
- `FCM_TOKEN_SYNC_URL`: should point to `https://<project>.vercel.app/api/register-token`
- `FCM_TOKEN_SYNC_BEARER`: must match `FCM_TOKEN_SYNC_BEARER` env var configured in Vercel

## deploy in vercel

1. import the repository in Vercel.
2. set `Root Directory` to `vercel-connector`.
3. framework preset: `Other`.
4. add environment variables for Preview and Production.
5. deploy.
6. copy endpoint: `https://<project>.vercel.app/api/flespi-webhook`.

## test webhook with curl

```bash
curl -X POST "https://<project>.vercel.app/api/flespi-webhook" \
  -H "Authorization: Bearer <WEBHOOK_BEARER_SECRET>" \
  -H "Content-Type: application/json" \
  -d '{
    "event_id": "evt-001",
    "device_id": "123456",
    "event_type": "geofence_exit",
    "title": "Alerta de geocerca",
    "body": "Vehiculo fuera de zona",
    "severity": "high",
    "ts": 1774137600000
  }'
```

## expected response

- `200`: push dispatch attempted; includes success/failure counters.
- `202`: no active tokens found for the routing key.
- `400`: invalid payload or missing `device_id` and `user_id`.
- `401`: invalid bearer token.
- `5xx`: processing or configuration error.
