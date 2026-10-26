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

Node types: `column`, `row`, `wrap`, `card {title, icon, text}`, `text {text, style: title|headline|caption|mono|big, color}`, `button {label, icon, prominent, disabled, onClick}`, `toggle {label, value, onChange}`, `picker {label, value, options:[{value,label}], onChange}`, `slider {label, value, min, max, onChange}`, `field {label, value, placeholder, onSubmit}`, `progress {label, value, max}`, `meter {label, value, max, warn, bad, format}`, `divider`, `spacer`.
Colors: `red green orange yellow blue teal gray` or `#RRGGBB`. Icons are SF Symbols names.

## Safety

- Add-ons are code from files: enable only those you trust.
- The runtime has no file or network access beyond what the API above exposes.
- Parameter writes are refused while ARMED; flight commands need the `commands` permission.
- Never block the JS thread with long loops: everything runs on the app's main thread.

