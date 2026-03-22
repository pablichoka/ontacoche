# ontacoche vercel connector

Serverless webhook connector to deliver Flespi events to Firebase Cloud Messaging.

## flow

`tracker -> flespi -> vercel -> firebase -> app`

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

## required environment variables

- `WEBHOOK_BEARER_SECRET`: shared secret used by Flespi webhook authorization header.
- `FCM_TOKEN_SYNC_BEARER`: shared secret used by the mobile app when syncing FCM tokens.
- `FIREBASE_PROJECT_ID`: Firebase project id.
- `FIREBASE_CLIENT_EMAIL`: service account client email.
- `FIREBASE_PRIVATE_KEY`: service account private key (escaped newlines are supported).

## optional environment variables

- `FCM_TOKEN_COLLECTION`: Firestore collection name. default: `fcm_tokens`
- `DEFAULT_DEVICE_ID`: fallback routing key when incoming event has no `device_id`/`user_id` (useful for single-device stream setup)
- `LOG_LEVEL`: not enforced yet, default: `info`

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
