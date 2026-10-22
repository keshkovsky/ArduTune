using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using static MAVLink;

/// Додаткове обладнання: версія автопілота, ADS-B, далекоміри, підвіс і DroneCAN (через CAN_FRAME, MAV_CMD_CAN_FORWARD).
/// Усі поля розбираються з сирих байтів: рефлексія на packed-структурах небезпечна на Apple Silicon.
partial class Link
{
    // ---------- AUTOPILOT_VERSION ----------
    byte[] apVer;
    DateTime lastApReq = DateTime.MinValue;

    public object ApVersion()
    {
        if (apVer == null)
        {
            Cmd(MAV_CMD.REQUEST_MESSAGE, 148);
            for (int i = 0; i < 20 && apVer == null; i++) Thread.Sleep(100);
        }
        var p = apVer; if (p == null) return null;
        uint sw = BitConverter.ToUInt32(p, 16);
        string Hex(int o, int n) => string.Concat(p.Skip(o).Take(n).Select(b => b.ToString("x2")));
        string Ver(uint v)
        {
            var t = v & 255; string ty = t == 255 ? "official" : t >= 192 ? "rc" : t >= 128 ? "beta" : t >= 64 ? "alpha" : "dev";
            return $"{v >> 24}.{(v >> 16) & 255}.{(v >> 8) & 255}-{ty}";
        }
        string GitStr(int o) { var s = Encoding.ASCII.GetString(p, o, 8).TrimEnd('\0'); return s.All(ch => ch >= 32 && ch < 127) && s.Length > 0 ? s : Hex(o, 8); }
        return new
        {
            capabilities = BitConverter.ToUInt64(p, 0),
            uid = BitConverter.ToUInt64(p, 8).ToString("x16"),
            uid2 = Hex(60, 18),
            flight = Ver(sw), flightRaw = sw,
            middleware = BitConverter.ToUInt32(p, 20), os = Ver(BitConverter.ToUInt32(p, 24)),
            boardVersion = BitConverter.ToUInt32(p, 28), vendorId = BitConverter.ToUInt16(p, 32), productId = BitConverter.ToUInt16(p, 34),
            flightGit = GitStr(36), middlewareGit = GitStr(44), osGit = GitStr(52),
        };
    }

    // ---------- USB-пристрої (назва плати з дескриптора) ----------
    /// ArduPilot/PX4 пишуть назву плати в USB Product Name (наприклад, «MatekH743-bdshot»): надійніше за повідомлення, що лишились від попереднього підключення.
    public object UsbBoards()
    {
        var res = new List<object>(); string err = null;
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("/usr/sbin/ioreg", "-r -c IOUSBHostDevice -l") { RedirectStandardOutput = true, UseShellExecute = false };
            using var pr = System.Diagnostics.Process.Start(psi);
            var txt = pr.StandardOutput.ReadToEnd(); pr.WaitForExit(5000);
            foreach (var b in System.Text.RegularExpressions.Regex.Split(txt, @"\n(?=\+-o )"))
            {
                var ports = System.Text.RegularExpressions.Regex.Matches(b, @"""IOCalloutDevice"" = ""([^""]*)""").Select(m => m.Groups[1].Value).ToList();
                if (ports.Count == 0) continue;
                string S(string k) { var m = System.Text.RegularExpressions.Regex.Match(b, "\"" + k + "\" = \"([^\"]*)\""); return m.Success ? m.Groups[1].Value : ""; }
                string N(string k) { var m = System.Text.RegularExpressions.Regex.Match(b, "\"" + k + "\" = (\\d+)"); return m.Success ? m.Groups[1].Value : "0"; }
                res.Add(new { product = S("USB Product Name"), vendor = S("USB Vendor Name"), serial = S("USB Serial Number"), vid = int.Parse(N("idVendor")), pid = int.Parse(N("idProduct")), ports });
            }
        }
        catch (Exception e) { err = e.Message; }
        string cur; lock (lk) cur = T.port;
        return new { current = cur, devices = res, error = err };
    }

    // ---------- MAVLink-інспектор ----------
    class MsgStat { public int id, sys, comp, count, win; public double hz; public DateTime last, winStart; }
    readonly Dictionary<string, MsgStat> msgStats = new Dictionary<string, MsgStat>();

    public object MsgStatsList()
    {
        lock (lk)
        {
            var now = DateTime.UtcNow;
            return msgStats.OrderBy(k => k.Key, StringComparer.Ordinal).Select(k => new { name = k.Key, k.Value.id, k.Value.sys, k.Value.comp, k.Value.count, hz = (now - k.Value.last).TotalSeconds > 2.5 ? 0 : k.Value.hz, age = (now - k.Value.last).TotalSeconds }).ToList();
        }
    }
    public void MsgStatsReset() { lock (lk) { foreach (var s in msgStats.Values) { s.count = 0; s.win = 0; s.winStart = DateTime.UtcNow; } } }

    // ---------- ADS-B ----------
    class Adsb { public uint icao; public double lat, lon, alt, heading, speed, climb; public string callsign = ""; public int emitter, squawk, flags, altType; public DateTime seen; }
    readonly Dictionary<uint, Adsb> adsb = new Dictionary<uint, Adsb>();
    readonly object hwLk = new object();

    public object AdsbList()
    {
        lock (hwLk)
        {
            var now = DateTime.UtcNow;
            foreach (var k in adsb.Where(kv => (now - kv.Value.seen).TotalSeconds > 90).Select(kv => kv.Key).ToList()) adsb.Remove(k);
            return adsb.Values.OrderBy(a => a.icao).Select(a => new { icao = a.icao.ToString("X6"), a.callsign, a.lat, a.lon, alt = a.alt, a.heading, a.speed, a.climb, a.emitter, a.squawk, a.flags, age = (now - a.seen).TotalSeconds }).ToList();
        }
    }

    // ---------- Далекоміри ----------
    class Rng { public int id, orient, type; public double dist, min, max; public DateTime seen; public string src = ""; }
    readonly Dictionary<string, Rng> rng = new Dictionary<string, Rng>();

    public void HwReset() { lock (hwLk) { rng.Clear(); adsb.Clear(); dcNodes.Clear(); dcAsm.Clear(); dcBus = 0; dcFrames = 0; dcTransfers = 0; } }

    public object RangeList()
    {
        lock (hwLk)
        {
            var now = DateTime.UtcNow;
            return rng.Values.Where(r => (now - r.seen).TotalSeconds < 60).OrderBy(r => r.src).ThenBy(r => r.id).Select(r => new { r.id, r.orient, r.type, r.dist, r.min, r.max, r.src, age = (now - r.seen).TotalSeconds }).ToList();
        }
    }

    // ---------- DroneCAN ----------
    class DcNode
    {
        public int id; public uint uptime; public int health, mode, sub, vendor; public DateTime seen, infoReq = DateTime.MinValue;
        public string name = "", hw = "", sw = "", uid = ""; public bool hasInfo; public uint vcs; public ulong crc;
        public Dictionary<int, int> counts = new Dictionary<int, int>();
        // живі дані uavcan.equipment.power.BatteryInfo (1092)
        public double battV, battA, battT, battSoc = -1; public DateTime battSeen = DateTime.MinValue;
        // параметри вузла (uavcan.protocol.param.GetSet, лише читання)
        public List<DcParam> prm = new List<DcParam>(); public bool prmBusy; public string prmErr = ""; public int prmWait = -1, prmGot = -1; public DcParam prmLast; public string prmRaw = "";
    }
    class DcParam { public int index; public string name = "", value = "", def = "", min = "", max = ""; public string type = ""; }

    /// Побітове читання за правилами DSDL UAVCAN v0: біти потоку йдуть від старшого біта байта, багатобайтові числа — молодшим байтом уперед.
    class BitR
    {
        readonly byte[] b; int pos;
        public BitR(byte[] x) { b = x; }
        public int Left => b.Length * 8 - pos;
        int Bits(int n) { int r = 0; for (int i = 0; i < n; i++) { int bit = pos < b.Length * 8 ? (b[pos >> 3] >> (7 - (pos & 7))) & 1 : 0; r = (r << 1) | bit; pos++; } return r; }
        public ulong U(int n)
        {
            ulong v = 0; int full = n / 8, rem = n % 8;
            for (int k = 0; k < full; k++) v |= (ulong)Bits(8) << (8 * k);
            if (rem > 0) v |= (ulong)Bits(rem) << (8 * full);
            return v;
        }
    }
    readonly Dictionary<int, DcNode> dcNodes = new Dictionary<int, DcNode>();
    readonly Dictionary<string, (List<byte> buf, int tid, bool multi)> dcAsm = new Dictionary<string, (List<byte>, int, bool)>();
    int dcBus; DateTime dcKeep = DateTime.MinValue; Thread dcThread; int dcFrames, dcTransfers; byte dcTid; DateTime dcLastFrame = DateTime.MinValue;
    const int OurNode = 124;

    public void DcStart(int bus)
    {
        lock (hwLk) { dcBus = bus; dcKeep = DateTime.UtcNow; dcFrames = 0; dcTransfers = 0; dcNodes.Clear(); dcAsm.Clear(); }
        if (dcThread == null || !dcThread.IsAlive)
        {
            dcThread = new Thread(() =>
            {
                while (true)
                {
                    int b; bool alive;
                    lock (hwLk) { b = dcBus; alive = (DateTime.UtcNow - dcKeep).TotalSeconds < 20; }
                    if (b > 0 && alive) Cmd(MAV_CMD.CAN_FORWARD, b);
                    else if (b > 0 && !alive) { Cmd(MAV_CMD.CAN_FORWARD, 0); lock (hwLk) dcBus = 0; }
                    Thread.Sleep(2000);
                }
            }) { IsBackground = true }; dcThread.Start();
        }
        Cmd(MAV_CMD.CAN_FORWARD, bus);
    }
    public void DcStop() { lock (hwLk) { dcBus = 0; } Cmd(MAV_CMD.CAN_FORWARD, 0); }

    public object DcState()
    {
        lock (hwLk)
        {
            dcKeep = DateTime.UtcNow;
            var now = DateTime.UtcNow;
            foreach (var n in dcNodes.Values.Where(n => !n.hasInfo && (now - n.infoReq).TotalSeconds > 3).ToList()) { n.infoReq = now; DcRequestInfo(n.id); }
            return new
            {
                bus = dcBus, frames = dcFrames, transfers = dcTransfers, lastFrameAge = dcFrames == 0 ? -1 : (now - dcLastFrame).TotalSeconds,
                nodes = dcNodes.Values.OrderBy(n => n.id).Select(n => new
                {
                    n.id, n.uptime, n.health, n.mode, n.sub, n.vendor, age = (now - n.seen).TotalSeconds, n.name, n.hw, n.sw, n.uid, n.hasInfo, vcs = n.vcs.ToString("x8"),
                    messages = n.counts.OrderByDescending(c => c.Value).Take(12).Select(c => new { type = c.Key, count = c.Value }).ToList(),
                    battery = n.battSeen == DateTime.MinValue ? null : new { voltage = n.battV, current = n.battA, tempC = n.battT, soc = n.battSoc, age = (now - n.battSeen).TotalSeconds },
                    paramCount = n.prm.Count, paramBusy = n.prmBusy,
                }).ToList(),
            };
        }
    }

    /// Одно-кадровий запит сервісу (корисне навантаження до 7 байт).
    void DcSendService(int node, int typeId, byte[] payload)
    {
        uint id = 0x80000000u | (24u << 24) | ((uint)typeId << 16) | (1u << 15) | ((uint)(node & 0x7F) << 8) | (1u << 7) | OurNode;
        var d = new byte[8]; Array.Copy(payload, d, payload.Length);
        d[payload.Length] = (byte)(0xC0 | (dcTid++ & 31));
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.CAN_FRAME, new mavlink_can_frame_t(id, targetSys, targetComp, (byte)Math.Max(0, dcBus - 1), (byte)(payload.Length + 1), d), false, 255, 190, 0));
    }

    /// Читання всіх параметрів вузла по індексу (GetSet з порожнім значенням: нічого не змінює). Порожня назва = кінець списку.
    public bool DcReadParams(int node)
    {
        DcNode n;
        lock (hwLk) { if (!dcNodes.TryGetValue(node, out n) || n.prmBusy || dcBus == 0) return false; n.prmBusy = true; n.prm = new List<DcParam>(); n.prmErr = ""; }
        System.Threading.Tasks.Task.Run(() =>
        {
            try
            {
                for (int idx = 0; idx < 512; idx++)
                {
                    DcParam got = null;
                    for (int attempt = 0; attempt < 4 && got == null; attempt++)
                    {
                        lock (hwLk) { n.prmWait = idx; n.prmGot = -1; n.prmLast = null; dcKeep = DateTime.UtcNow; }
                        DcSendService(node, 11, new byte[] { (byte)(idx & 0xFF), (byte)(((idx >> 8) & 0x1F) << 3) });   // index(13) + void3; без значення й назви (підтверджено реальним вузлом: третій байт сприймається як назва)
                        for (int w = 0; w < 60 && got == null; w++) { Thread.Sleep(20); lock (hwLk) { if (n.prmGot == idx) got = n.prmLast; } }
                    }
                    if (got == null) { lock (hwLk) n.prmErr = $"Вузол не відповів на параметр {idx}"; break; }
                    if (got.name.Length == 0) break;
                    got.index = idx;
                    lock (hwLk) n.prm.Add(got);
                }
            }
            finally { lock (hwLk) n.prmBusy = false; }
        });
        return true;
    }

    public object DcParams(int node)
    {
        lock (hwLk)
        {
            if (!dcNodes.TryGetValue(node, out var n)) return new { busy = false, error = "Вузла немає", items = new object[0] };
            return new { busy = n.prmBusy, error = n.prmErr, raw = n.prmRaw, items = n.prm.Select(p => new { p.index, p.name, p.type, p.value, p.def, p.min, p.max }).ToList() };
        }
    }

    void DcRequestInfo(int node)
    {
        // службовий запит uavcan.protocol.GetNodeInfo (тип 1), без корисного навантаження: один кадр
        uint id = 0x80000000u | (24u << 24) | (1u << 16) | (1u << 15) | ((uint)(node & 0x7F) << 8) | (1u << 7) | OurNode;   // біт 31 = CAN_EFF_FLAG (розширений 29-бітний ідентифікатор), як у прийнятих кадрах
        var d = new byte[8]; d[0] = (byte)(0xC0 | (dcTid++ & 31));
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.CAN_FRAME, new mavlink_can_frame_t(id, targetSys, targetComp, (byte)Math.Max(0, dcBus - 1), 1, d), false, 255, 190, 0));
    }

    void HardwareIntercept(MAVLinkMessage m)
    {
        switch ((MAVLINK_MSG_ID)m.msgid)
        {
            case MAVLINK_MSG_ID.AUTOPILOT_VERSION:
            {
                apVer = Pad(Payload(m), 78);
                uint sw = BitConverter.ToUInt32(apVer, 16);
                if (sw != 0) Meta.ForVersion((int)(sw >> 24), (int)((sw >> 16) & 255), (int)((sw >> 8) & 255), (int)(sw & 255));
                break;
            }
            case MAVLINK_MSG_ID.STATUSTEXT:
            {
                // запасний шлях: «ArduPlane V4.7.0-dev (…)» у повідомленнях запуску
                var p = Pad(Payload(m), 54);
                var s = Encoding.ASCII.GetString(p, 1, 50).TrimEnd('\0');
                var rm = System.Text.RegularExpressions.Regex.Match(s, @"^(?:Ardu\w+|Rover|AntennaTracker|Blimp) V(\d+)\.(\d+)\.(\d+)(?:-(\w+))?");
                if (rm.Success && apVer == null)
                {
                    var tp = rm.Groups[4].Success ? rm.Groups[4].Value.ToLower() : "";
                    int ty = tp == "" ? 255 : tp.StartsWith("rc") ? 192 : tp.StartsWith("beta") ? 128 : tp.StartsWith("alpha") ? 64 : 0;
                    Meta.ForVersion(int.Parse(rm.Groups[1].Value), int.Parse(rm.Groups[2].Value), int.Parse(rm.Groups[3].Value), ty);
                }
                break;
            }
            case MAVLINK_MSG_ID.ADSB_VEHICLE:
            {
                var p = Pad(Payload(m), 38);
                var a = new Adsb
                {
                    icao = BitConverter.ToUInt32(p, 0), lat = BitConverter.ToInt32(p, 4) / 1e7, lon = BitConverter.ToInt32(p, 8) / 1e7, alt = BitConverter.ToInt32(p, 12) / 1000.0,
                    heading = BitConverter.ToUInt16(p, 16) / 100.0, speed = BitConverter.ToUInt16(p, 18) / 100.0, climb = BitConverter.ToInt16(p, 20) / 100.0,
                    flags = BitConverter.ToUInt16(p, 22), squawk = BitConverter.ToUInt16(p, 24), altType = p[26], emitter = p[36], seen = DateTime.UtcNow,
                    callsign = Encoding.ASCII.GetString(p, 27, 9).TrimEnd('\0', ' '),
                };
                lock (hwLk) adsb[a.icao] = a;
                break;
            }
            case MAVLINK_MSG_ID.DISTANCE_SENSOR:
            {
                var p = Pad(Payload(m), 14);
                var r = new Rng { min = BitConverter.ToUInt16(p, 4) / 100.0, max = BitConverter.ToUInt16(p, 6) / 100.0, dist = BitConverter.ToUInt16(p, 8) / 100.0, type = p[10], id = p[11], orient = p[12], seen = DateTime.UtcNow, src = "DISTANCE_SENSOR" };
                lock (hwLk) rng["d" + r.id + ":" + r.orient] = r;
                break;
            }
            case MAVLINK_MSG_ID.RANGEFINDER:
            {
                var p = Pad(Payload(m), 8);
                var r = new Rng { dist = BitConverter.ToSingle(p, 0), seen = DateTime.UtcNow, src = "RANGEFINDER", id = 0, orient = 25 };
                lock (hwLk) rng["r"] = r;
                break;
            }
            case MAVLINK_MSG_ID.CAN_FRAME:
            {
                var p = Pad(Payload(m), 16);
                DcFeed(BitConverter.ToUInt32(p, 0), p.Skip(8).Take(8).ToArray(), Math.Min((int)p[7], 8));
                break;
            }
            case MAVLINK_MSG_ID.CANFD_FRAME:
            {
                var p = Pad(Payload(m), 72);
                DcFeed(BitConverter.ToUInt32(p, 0), p.Skip(8).Take(64).ToArray(), Math.Min((int)p[7], 64));
                break;
            }
        }
    }

    /// Збирання передач DroneCAN з кадрів (хвостовий байт: старт, кінець, toggle, ідентифікатор передачі).
    void DcFeed(uint id, byte[] data, int len)
    {
        if (len < 1) return;
        byte tail = data[len - 1];
        bool sot = (tail & 0x80) != 0, eot = (tail & 0x40) != 0; int tid = tail & 31;
        int src = (int)(id & 0x7F); bool svc = ((id >> 7) & 1) != 0;
        int typeId = svc ? (int)((id >> 16) & 0xFF) : (int)((id >> 8) & 0xFFFF);
        bool req = svc && ((id >> 15) & 1) != 0; int dest = svc ? (int)((id >> 8) & 0x7F) : 0;
        if (src == 0) return;              // анонімні передачі пропускаємо
        lock (hwLk)
        {
            dcFrames++; dcLastFrame = DateTime.UtcNow;
            string key = $"{src}/{typeId}/{(svc ? 1 : 0)}/{(req ? 1 : 0)}/{dest}";
            if (sot) dcAsm[key] = (new List<byte>(), tid, !eot);
            else if (!dcAsm.ContainsKey(key) || dcAsm[key].tid != tid) return;
            var cur = dcAsm[key];
            cur.buf.AddRange(data.Take(len - 1));
            if (!eot) return;
            var payload = cur.buf.ToArray(); dcAsm.Remove(key);
            if (cur.multi && payload.Length >= 2) payload = payload.Skip(2).ToArray();         // 16-біт CRC передачі (не перевіряємо)
            dcTransfers++;
            DcHandle(src, svc, typeId, req, dest, payload);
        }
    }

    void DcHandle(int src, bool svc, int typeId, bool req, int dest, byte[] p)
    {
        if (!dcNodes.TryGetValue(src, out var n)) dcNodes[src] = n = new DcNode { id = src };
        n.seen = DateTime.UtcNow;
        if (!svc)
        {
            n.counts[typeId] = n.counts.GetValueOrDefault(typeId) + 1;
            if (typeId == 341 && p.Length >= 7) DcStatus(n, p);
            if (typeId == 1092 && p.Length >= 6) DcBattery(n, p);
        }
        else if (typeId == 11 && !req && dest == OurNode && n.prmWait >= 0)
        {
            n.prmRaw = BitConverter.ToString(p).Replace("-", ""); n.prmLast = DcParseGetSet(p); n.prmGot = n.prmWait;
        }
        else if (typeId == 1 && !req && dest == OurNode && p.Length >= 22 + 1 + 17)
        {
            DcStatus(n, p);
            n.sw = $"{p[7]}.{p[8]}"; n.vcs = BitConverter.ToUInt32(p, 10); n.crc = BitConverter.ToUInt64(p, 14);
            n.hw = $"{p[22]}.{p[23]}"; n.uid = string.Concat(p.Skip(24).Take(16).Select(b => b.ToString("x2")));
            int coa = p[40]; int nameAt = 41 + coa;
            n.name = nameAt <= p.Length ? Encoding.ASCII.GetString(p, nameAt, p.Length - nameAt).TrimEnd('\0') : "";
            n.hasInfo = true;
        }
    }
    static string DcValue(BitR r, int tag)
    {
        switch (tag)
        {
            case 1: return ((long)r.U(64)).ToString();
            case 2: return BitConverter.Int32BitsToSingle((int)(uint)r.U(32)).ToString("0.######", System.Globalization.CultureInfo.InvariantCulture);
            case 3: return r.U(8) != 0 ? "true" : "false";
            case 4: { int len = (int)r.U(8); var sb = new StringBuilder(); for (int i = 0; i < len && r.Left >= 8; i++) sb.Append((char)r.U(8)); return sb.ToString(); }
            default: return "";
        }
    }
    static string DcNumeric(BitR r)
    {
        int tag = (int)r.U(8);                       // теги union у DSDL цього сервісу займають цілий байт (підтверджено реальним вузлом)
        return tag == 1 ? ((long)r.U(64)).ToString() : tag == 2 ? BitConverter.Int32BitsToSingle((int)(uint)r.U(32)).ToString("0.######", System.Globalization.CultureInfo.InvariantCulture) : "";
    }
    /// Відповідь uavcan.protocol.param.GetSet: value, default_value, max_value, min_value, name (хвостовий масив).
    static DcParam DcParseGetSet(byte[] p)
    {
        var r = new BitR(p); var o = new DcParam();
        int t1 = (int)r.U(8); o.value = DcValue(r, t1); o.type = t1 switch { 1 => "int", 2 => "float", 3 => "bool", 4 => "string", _ => "" };
        int t2 = (int)r.U(8); o.def = DcValue(r, t2);
        o.max = DcNumeric(r); o.min = DcNumeric(r);
        var sb = new StringBuilder();
        while (r.Left >= 8) { int c = (int)r.U(8); if (c == 0) break; sb.Append((char)c); }
        o.name = sb.ToString();
        return o;
    }
    static void DcBattery(DcNode n, byte[] p)
    {
        double H(int i) => (double)BitConverter.UInt16BitsToHalf((ushort)(p[i] | p[i + 1] << 8));
        n.battT = H(0) - 273.15; n.battV = H(2); n.battA = H(4); n.battSeen = DateTime.UtcNow;
        if (p.Length >= 17)
        {
            var r = new BitR(p); for (int i = 0; i < 12; i++) r.U(8);
            r.U(12); r.U(11); r.U(7);                                  // hours_to_full_charge, status_flags, state_of_health
            n.battSoc = r.U(7);
        }
    }
    static void DcStatus(DcNode n, byte[] p)
    {
        n.uptime = BitConverter.ToUInt32(p, 0); n.health = p[4] >> 6; n.mode = (p[4] >> 3) & 7; n.sub = p[4] & 7; n.vendor = p[5] | (p[6] << 8);
    }
}
