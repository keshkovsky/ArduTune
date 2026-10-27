# ArduTune add-ons

Add-ons extend ArduTune with support for new devices, panels, HUD lines and map overlays. An add-on is a **folder** with a manifest and a JavaScript file. ArduTune scans the folder at start-up, runs each enabled add-on in an isolated JavaScriptCore context and gives it the `ardutune` API according to the permissions you grant.

Folder: `~/Library/Application Support/ArduTune/Addons/<your-addon>/` (open it from **Add-ons → Open folder**).

```
my-addon/
  addon.json
  main.js
```

## Manifest (`addon.json`)

```json
{
  "id": "my-addon",
  "name": "My device",
  "version": "1.0.0",
  "author": "you",
  "description": "What it does",
  "main": "main.js",
  "icon": "puzzlepiece.extension",
  "permissions": ["telemetry", "serial", "ui", "hud", "map", "params.read", "params.write", "commands"]
}
```

The user enables an add-on in **Add-ons**, which grants the permissions it declared (each can be revoked separately). Without a permission the corresponding API logs an error and does nothing.

| Permission | Allows |
|---|---|
| `telemetry` | `ardutune.telemetry()`, `ardutune.on('telemetry', …)` |
| `params.read` / `params.write` | `ardutune.params.*` (writes are refused while ARMED) |
| `commands` | `ardutune.cmd.long()` (MAVLink COMMAND_LONG) |
| `serial` | `ardutune.serial.*` (only `/dev/cu.*` USB ports) |
| `net` | `ardutune.net.open()` (TCP/UDP, лише приватні IPv4: 10.x, 172.16–31.x, 192.168.x, 169.254.x) |
| `mavlink` | `ardutune.mavlink.send()` / `get()` (raw MAVLink by message name) |
| `http` | `ardutune.http.request()` to private LAN addresses (http or https) |
| `internet` | `ardutune.http.request()` to public hosts (HTTPS only; never localhost or private ranges) |
| `ui` | `ardutune.ui.page()` |
| `hud` | `ardutune.hud.lines()` |
| `map` | `ardutune.map.*`, `ardutune.menu.add()` |

## API

Globals: `console.log`, `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`.

```js
ardutune.lang            // 'uk' | 'en'
ardutune.version         // app version
ardutune.dir             // add-on folder path
ardutune.log(...)        // add-on log (Add-ons → Log)

ardutune.telemetry()     // snapshot: { connected, armed, mode, vehicle, lat, lon, altRel, altMsl, groundSpeed,
                         //             heading, gpsFix, sats, batteryV, batteryA, batteryPct, ... }
ardutune.on('telemetry', t => {})     // ~2 Hz
ardutune.on('connection', connected => {})

ardutune.params.has(name) / get(name) / set(name, value)

ardutune.cmd.long(command, p1, p2, p3, p4, p5, p6, p7)

const port = ardutune.serial.open('/dev/cu.usbserial-1', { baud: 115200 })   // 8N1
ardutune.serial.list()   // available /dev/cu.usb* ports
port.write([0xFE, 0xEF, …]); port.onData(bytes => {}); port.onClose(() => {}); port.isOpen(); port.close()

const sock = ardutune.net.open({ host: '192.168.3.102', port: 5000, proto: 'tcp' })   // 'tcp' | 'udp'
sock.onOpen(() => {}); sock.onData(bytes => {}); sock.onClose(() => {}); sock.write([…]); sock.isOpen(); sock.close()

// raw MAVLink (permission `mavlink`). Fields are given by their MAVLink names; arrays as arrays, char arrays as strings.
ardutune.mavlink.send('NAMED_VALUE_FLOAT', { time_boot_ms: 0, name: 'MYVAL', value: 1.5 }, { sys: 255, comp: 190 })   // sys/comp optional
ardutune.mavlink.get('GLOBAL_POSITION_INT')   // → { age: seconds since last message, fields: { lat: 504500000, … } } or null
// Not sendable: COMMAND_LONG/INT, SET_MODE, PARAM_SET, MISSION_*, FILE_TRANSFER_PROTOCOL, SERIAL_CONTROL, LOG_ERASE (use the dedicated APIs).

// HTTP (permission `http` for LAN, `internet` for public HTTPS)
ardutune.http.request({ url: 'http://192.168.3.1/status', method: 'GET', headers: {}, body: '…' | {json}, timeout: 10 },
                      res => { /* res.status, res.body (text, ≤2 MB), res.error */ })

ardutune.storage.get(key, default) / set(key, value)    // persisted next to the add-on (storage.json)

ardutune.hud.lines(['text', …])                          // extra HUD text lines

ardutune.map.markers([{ id, lat, lon, title, symbol: 'mappin', color: '#FF3B30' }])
ardutune.map.lines([{ id, points: [[lat, lon], …], color: '#30B0C7', dashed: true }])
ardutune.menu.add({ title: 'Do something here', onClick: ({ lat, lon }) => {} })   // map context menu (Flight Data)
```

## UI

Pages are declarative. `render()` is called a few times per second and must return a tree of plain objects; ArduTune draws it in its own style. Handlers (`onClick`, `onChange`, `onSubmit`) are plain functions in the tree.

```js
ardutune.ui.page({
  id: 'main', title: 'My device', icon: 'puzzlepiece', location: 'optional',   // 'addons' | 'optional' | 'flight'
  render: () => ({ type: 'column', children: [
    { type: 'card', title: 'Status', icon: 'dot.radiowaves.right', children: [
      { type: 'text', text: 'Hello', style: 'big' },
      { type: 'button', label: 'Go', icon: 'bolt.fill', prominent: true, onClick: () => {} },
      { type: 'toggle', label: 'Enabled', value: state.on, onChange: v => { state.on = v; } },
    ]},
  ]}),
});
```

`location`: `addons` = a tab inside the **Add-ons** page, `optional` = a tab in **Optional Hardware**, `flight` = the **Add-ons** tab at the bottom of Flight Data.

Node types: `column`, `row`, `wrap`, `card {title, icon, text}`, `text {text, style: title|headline|caption|mono|big, color}`, `button {label, icon, prominent, disabled, width, key, onClick}` (`key`: "up" | "down" | "left" | "right" | "return" | "delete" | "space" | "escape" | a letter: keyboard shortcut while the page is visible and no text field is focused; disabled buttons ignore it), `toggle {label, value, onChange}`, `picker {label, value, options:[{value,label}], onChange}`, `slider {label, value, min, max, onChange}`, `field {label, value, placeholder, onSubmit}`, `progress {label, value, max}`, `meter {label, value, max, warn, bad, format}`, `divider`, `spacer` (`{type:'spacer'}` is flexible; with `width`/`height` it is a fixed empty gap).
Colors: `red green orange yellow blue teal gray` or `#RRGGBB`. Icons are SF Symbols names.

## Safety

- Add-ons are code from files: enable only those you trust.
- The runtime has no file access, and network access only through `net`, `http` and `internet` (LAN-only unless `internet` is granted).
- Parameter writes are refused while ARMED; flight commands need the `commands` permission.
- Never block the JS thread with long loops: everything runs on the app's main thread.

