# flespi geofence backup (2026-03-26)

## devices
- id: `7861297`
- name: `La Bmeta`
- ident: `009590067804`
- assignments: `calcs=1`, `geofences=2`, `streams=1`, `plugins=1`

## geofences
- `138141` -> `Casa de LaBmeta` (circle r=0.25)
- `138472` -> `AIT Parking` (circle r=0.06)

## calculator (legacy)
- id: `2657230`
- name: `LaBmeta geofence events`
- selector: `geofence()` change
- validate_message: `exists('position.latitude') && exists('position.longitude')`

## plugin (legacy)
- id: `1117230`
- name: `LaBmeta geofence status`
- type: `msg-geofence`

## streams (must keep)
- id: `1265492`
- name: `ontacoche-vercel-fcm-stream`
- protocol: `http`
- uri: `https://ontacoche.vercel.app/api/flespi-webhook`

## platform webhooks (legacy geofence)
- `14729` -> `ontacoche-geofence-calc-webhook` (disabled)
- `14730` -> `ontacoche-geofence-calc-webhook-v2` (enabled)

## goal of rebuild
- keep stream `1265492` for tracking + vibration
- remove legacy geofence plugin/calculator/webhooks
- recreate one calculator + one webhook for geofence enter/exit
