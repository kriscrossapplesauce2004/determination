# Determination Android app API

The Android API is a facade over the native `detd` protocol. The companion can
be killed or upgraded without stopping the guest, audio, or the control daemon.
There is no arbitrary command execution, Android property API, or PCM transport.

## Ordinary apps

Read-only status, capabilities, and metrics use explicit ordered broadcasts. Set the
component as well as the action so Android cannot deliver the query elsewhere:

```kotlin
val request = Intent("com.determination.action.STATUS").apply {
    component = ComponentName(
        "com.determination.companion",
        "com.determination.companion.DeterminationStatusReceiver",
    )
}
sendOrderedBroadcast(request, null, object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val protocolStatus = resultExtras.getInt("com.determination.extra.STATUS")
        val json = resultExtras.getString("com.determination.extra.JSON")
    }
}, null, 0, null, null)
```

The response is the native schema-versioned JSON. Status codes match the public
constants documented below; an empty payload with `-2` means the native bridge
is unavailable. Queries never fall back to an app-owned `su` shell.

Mode changes use an Activity Result contract and always show a Determination
confirmation dialog:

```kotlin
val request = Intent("com.determination.action.REQUEST_MODE").apply {
    component = ComponentName(
        "com.determination.companion",
        "com.determination.companion.DeterminationModeRequestActivity",
    )
    putExtra("com.determination.extra.MODE", "desktop") // or "phone"
}
launcher.launch(request)
```

The result includes `com.determination.extra.STATUS` and
`com.determination.extra.JSON`. Cancellation never changes state.

## Trusted apps

Apps signed with Determination's release certificate may request
`com.determination.permission.CONTROL` and bind explicitly with action
`com.determination.action.BIND_CONTROL`. The generated
`IDeterminationControl` interface provides:

- `getStatusJson()`;
- `getCapabilitiesJson()`;
- `getMetricsJson()`;
- `requestMode("phone" | "desktop")`.

The signature service permits silent mode requests because possession of the
release key is the trust boundary. It still forwards only fixed structured
operations; it cannot execute a shell string. A future public SDK should vendor
the AIDL and constants from this tree rather than copying native packet layouts.

## Status codes

| Value | Meaning |
|---:|---|
| `0` | completed |
| `1` | accepted asynchronously |
| `-1` | rejected by current state or policy |
| `-2` | native service unavailable |
| `-3` | deadline exceeded |
| `-4` | another transition/request is busy |
| `-5` | protocol mismatch |
| `-6` | invalid request |
| `-7` | permission denied |
| `-8` | recovery required |
| `-9` | internal error |

API major version 1 is additive: fields and methods may be added, but existing
meanings do not change. A breaking contract requires a new action/AIDL package
and an overlap release.
