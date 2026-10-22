using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Ports;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using static MAVLink;

// Двигун: тримає USB/serial з'єднання з ArduPilot, парсить MAVLink і віддає стан через WebSocket.
class Telemetry
{
    public bool connected { get; set; }
    public string port { get; set; }
    public string vehicle { get; set; }
    public string mode { get; set; }
    public bool armed { get; set; }
    public double roll { get; set; }
    public double pitch { get; set; }
    public double yaw { get; set; }
    public double lat { get; set; }
    public double lon { get; set; }
    public double altRel { get; set; }
    public double groundSpeed { get; set; }
    public double airSpeed { get; set; }
    public double heading { get; set; }
    public double cog { get; set; } = -1;          // курс GPS над землею, ° (-1 = невідомо)
    public double magHdg { get; set; } = -1;       // курс за магнітометром (з нахилом), ° (-1 = немає компаса)
    public double climb { get; set; }
    public double batteryV { get; set; }
    public double batteryA { get; set; }
    public int batteryPct { get; set; }
    public int gpsFix { get; set; }
    public int sats { get; set; }
    public string lastText { get; set; }
    public double msgRate { get; set; }
    public int customMode { get; set; }
    public double altMsl { get; set; }
    public double throttle { get; set; }
    public double navRoll { get; set; }
    public double navPitch { get; set; }
    public double wpDist { get; set; }
    public int wpSeq { get; set; }
    public int wpTotal { get; set; }
    public int wpReached { get; set; } = -1;
    public double vibeX { get; set; }
    public double vibeY { get; set; }
    public double vibeZ { get; set; }
    public double hdop { get; set; }
    public double rssi { get; set; }
    public double mahUsed { get; set; }
    public double homeLat { get; set; }
    public double homeLon { get; set; }
    public bool homeSet { get; set; }
    public double timeInAir { get; set; }
    public double distTraveled { get; set; }
    public int ekfFlags { get; set; }
    public bool gpsHealthy { get; set; }
    public bool visoPresent { get; set; }
    public bool visoHealthy { get; set; }
    public double ekfVelVar { get; set; }
    public double ekfPosHVar { get; set; }
    public double ekfPosVVar { get; set; }
    public double ekfCompassVar { get; set; }
    public double ekfTerrainVar { get; set; }
    public double vibeClip0 { get; set; }
    public double vibeClip1 { get; set; }
    public double vibeClip2 { get; set; }
    public string linkType { get; set; }
    public string linkState { get; set; }
    public bool booting { get; set; }
    public string linkError { get; set; }
    public string metaSource { get; set; }
    public bool recording { get; set; }
    public string recordFile { get; set; }
    public bool replaying { get; set; }
    public double replayProgress { get; set; }
    public double replaySpeed { get; set; }
}

static class Mode
{
    static readonly string[] Copter = { "Stabilize","Acro","AltHold","Auto","Guided","Loiter","RTL","Circle","7","Land","9","Drift","11","Sport","Flip","AutoTune","PosHold","Brake","Throw","AvoidADSB","GuidedNoGPS","SmartRTL","FlowHold","Follow","ZigZag","SystemID","Heli_Autorotate","AutoRTL" };
    static readonly System.Collections.Generic.Dictionary<uint, string> Plane = new System.Collections.Generic.Dictionary<uint, string>
    { {0,"Manual"},{1,"Circle"},{2,"Stabilize"},{3,"Training"},{4,"Acro"},{5,"FlyByWireA"},{6,"FlyByWireB"},{7,"Cruise"},{8,"Autotune"},{10,"Auto"},{11,"RTL"},{12,"Loiter"},{13,"Takeoff"},{14,"AvoidADSB"},{15,"Guided"},{17,"QStabilize"},{18,"QHover"},{19,"QLoiter"},{20,"QLand"},{21,"QRTL"},{22,"QAutotune"},{23,"QAcro"},{24,"Thermal"},{25,"LoiterAltQLand"},{26,"AutoLand"} };
    static readonly System.Collections.Generic.Dictionary<uint, string> Rover = new System.Collections.Generic.Dictionary<uint, string>
    { {0,"Manual"},{1,"Acro"},{3,"Steering"},{4,"Hold"},{5,"Loiter"},{6,"Follow"},{7,"Simple"},{8,"Dock"},{9,"Circle"},{10,"Auto"},{11,"RTL"},{12,"SmartRTL"},{15,"Guided"} };
    static readonly System.Collections.Generic.Dictionary<uint, string> Sub = new System.Collections.Generic.Dictionary<uint, string>
    { {0,"Stabilize"},{1,"Acro"},{2,"AltHold"},{3,"Auto"},{4,"Guided"},{7,"Circle"},{9,"Surface"},{16,"PosHold"},{19,"Manual"},{20,"Motordetect"},{21,"SurfTrak"} };
    static readonly System.Collections.Generic.Dictionary<uint, string> Tracker = new System.Collections.Generic.Dictionary<uint, string>
    { {0,"Manual"},{1,"Stop"},{2,"Scan"},{3,"Servo test"},{10,"Auto"},{16,"Initialising"} };

    public static string Name(byte type, uint m)
    {
        var t = (MAV_TYPE)type;
        System.Collections.Generic.Dictionary<uint, string> d = null;
        switch (t)
        {
            case MAV_TYPE.FIXED_WING: case MAV_TYPE.FLAPPING_WING: d = Plane; break;
            case MAV_TYPE.GROUND_ROVER: case MAV_TYPE.SURFACE_BOAT: d = Rover; break;
            case MAV_TYPE.SUBMARINE: d = Sub; break;
            case MAV_TYPE.ANTENNA_TRACKER: d = Tracker; break;
        }
        if (d == null && type >= 19 && type <= 24) d = Plane;      // VTOL (QuadPlane): режими ArduPlane
        if (d != null) return d.TryGetValue(m, out var n) ? n : "Mode" + m;
        // Мультикоптери та інше: ArduCopter
        return m < Copter.Length ? Copter[m] : "Mode" + m;
    }
}

class ConnCfg
{
    public string type = "auto";      // auto, serial, tcp, udp, udpcl, ws
    public string path;               // serial: /dev/cu.*
    public int baud = 115200;
    public string host;
    public int port;
}

/// Потік поверх черги байтів: читання з таймаутом 500 мс (кидає TimeoutException), запис через делегат.
class QueueStream : Stream
{
    readonly System.Collections.Concurrent.BlockingCollection<byte[]> q = new System.Collections.Concurrent.BlockingCollection<byte[]>();
    byte[] cur; int pos;
    readonly Action<byte[], int, int> write; readonly Action close;
    public volatile bool Dead;
    public QueueStream(Action<byte[], int, int> write, Action close) { this.write = write; this.close = close; }
    public void Push(byte[] d) { if (d != null && d.Length > 0 && !q.IsAddingCompleted) q.Add(d); }
    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;
    public override bool CanTimeout => true;
    public override int ReadTimeout { get => 500; set { } }
    public override int Read(byte[] buffer, int offset, int count)
    {
        if (cur == null || pos >= cur.Length)
        {
            if (!q.TryTake(out cur, 500)) { cur = null; if (Dead) throw new IOException("Підключення закрито"); throw new TimeoutException(); }
            pos = 0;
        }
        int n = Math.Min(count, cur.Length - pos);
        Array.Copy(cur, pos, buffer, offset, n); pos += n; return n;
    }
    public override void Write(byte[] buffer, int offset, int count) => write(buffer, offset, count);
    public override void Flush() { }
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override long Seek(long o, SeekOrigin so) => throw new NotSupportedException();
    public override void SetLength(long v) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { Dead = true; try { close?.Invoke(); } catch { } base.Dispose(disposing); }
}

static class Transport
{
    public static async Task<(Stream, string)> OpenAsync(ConnCfg c, CancellationToken ct)
    {
        switch (c.type)
        {
            case "serial":
            {
                var sp = new SerialPort(c.path, c.baud <= 0 ? 115200 : c.baud) { ReadTimeout = 500, WriteTimeout = 500, DtrEnable = true };
                sp.Open();
                return (new SerialStream(sp), c.path);
            }
            case "tcp":
            {
                var tc = new TcpClient { NoDelay = true };
                await tc.ConnectAsync(c.host, c.port).WaitAsync(TimeSpan.FromSeconds(6), ct);
                var ns = tc.GetStream();
                QueueStream qs = null;
                qs = new QueueStream((b, o, n) => ns.Write(b, o, n), () => tc.Close());
                _ = Task.Run(async () =>
                {
                    var buf = new byte[4096];
                    try { while (true) { int n = await ns.ReadAsync(buf, 0, buf.Length); if (n <= 0) break; qs.Push(buf.AsSpan(0, n).ToArray()); } } catch { }
                    qs.Dead = true;
                });
                return (qs, $"tcp:{c.host}:{c.port}");
            }
            case "udp":
            {
                var u = new UdpClient(c.port);
                IPEndPoint remote = null;
                QueueStream qs = null;
                qs = new QueueStream((b, o, n) => { var r = remote; if (r != null) u.Send(b.AsSpan(o, n).ToArray(), n, r); }, () => u.Close());
                _ = Task.Run(async () =>
                {
                    try { while (true) { var r = await u.ReceiveAsync(); remote = r.RemoteEndPoint; qs.Push(r.Buffer); } } catch { }
                    qs.Dead = true;
                });
                return (qs, $"udp:{c.port}");
            }
            case "udpcl":
            {
                var u = new UdpClient();
                u.Connect(c.host, c.port);
                QueueStream qs = null;
                qs = new QueueStream((b, o, n) => u.Send(b.AsSpan(o, n).ToArray(), n), () => u.Close());
                _ = Task.Run(async () =>
                {
                    try { while (true) { var r = await u.ReceiveAsync(); qs.Push(r.Buffer); } } catch { }
                    qs.Dead = true;
                });
                return (qs, $"udpci:{c.host}:{c.port}");
            }
            case "ws":
            {
                var ws = new ClientWebSocket();
                var url = c.host.Contains("://") ? c.host : $"ws://{c.host}:{c.port}";
                await ws.ConnectAsync(new Uri(url), ct).WaitAsync(TimeSpan.FromSeconds(6), ct);
                QueueStream qs = null;
                qs = new QueueStream((b, o, n) => ws.SendAsync(new ArraySegment<byte>(b, o, n), WebSocketMessageType.Binary, true, CancellationToken.None).GetAwaiter().GetResult(),
                    () => { try { ws.Abort(); ws.Dispose(); } catch { } });
                _ = Task.Run(async () =>
                {
                    var buf = new byte[8192];
                    try
                    {
                        while (ws.State == WebSocketState.Open)
                        {
                            var r = await ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None);
                            if (r.MessageType == WebSocketMessageType.Close) break;
                            if (r.Count > 0) qs.Push(buf.AsSpan(0, r.Count).ToArray());
                        }
                    }
                    catch { }
                    qs.Dead = true;
                });
                return (qs, url);
            }
        }
        throw new InvalidOperationException("Невідомий тип підключення: " + c.type);
    }
}

/// Обгортка, щоб закривати SerialPort разом із потоком.
class SerialStream : Stream
{
    readonly SerialPort sp; readonly Stream s;
    public SerialStream(SerialPort sp) { this.sp = sp; s = sp.BaseStream; }
    public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false;
    public override bool CanTimeout => true;
    public override int ReadTimeout { get => sp.ReadTimeout; set => sp.ReadTimeout = value; }
    public override int Read(byte[] b, int o, int c) { if (!sp.IsOpen) throw new IOException("Порт закрито"); return s.Read(b, o, c); }
    public override void Write(byte[] b, int o, int c) => s.Write(b, o, c);
    public override void Flush() => s.Flush();
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override long Seek(long o, SeekOrigin so) => throw new NotSupportedException();
    public override void SetLength(long v) => throw new NotSupportedException();
    protected override void Dispose(bool d) { try { sp.Close(); } catch { } base.Dispose(d); }
}

partial class Link
{
    readonly Telemetry T = new Telemetry();
    readonly object lk = new object();
    Stream io;
    volatile bool abort;
    ConnCfg cfg = new ConnCfg { type = "auto" };
    bool userDisconnected;
    volatile bool linkConnecting;
    string linkError;
    int count; DateTime rateT = DateTime.UtcNow;
    byte targetSys = 1, targetComp = 1, vtype;
    DateTime lastHb = DateTime.MinValue;
    DateTime hbSince = DateTime.MinValue;       // коли побачили перший heartbeat апарата на цьому зʼєднанні
    int sysStatus = -1;                         // MAV_STATE з останнього heartbeat (1 = BOOT)
    /// Плата завантажується (MAV_STATE_BOOT): їй не слать запити, поки не завершить ініціалізацію (до 2 хв, далі все одно починаємо).
    bool Booting => sysStatus == 1 && hbSince != DateTime.MinValue && (DateTime.UtcNow - hbSince).TotalSeconds < 120;
    readonly object wl = new object();
    class PItem { public string n; public float v; public byte t; public int idx; }
    readonly System.Collections.Generic.Dictionary<string, PItem> ps = new System.Collections.Generic.Dictionary<string, PItem>();
    int retryRounds; int pCount; bool pLoading; DateTime lastParam = DateTime.MinValue; bool autoRequested;
    readonly MavlinkParse gen = new MavlinkParse();

    static string Id(byte[] b) { var i = Array.IndexOf(b, (byte)0); return Encoding.ASCII.GetString(b, 0, i < 0 ? b.Length : i); }
    static byte[] IdBytes(string n) { var b = new byte[16]; Encoding.ASCII.GetBytes(n, 0, Math.Min(16, n.Length), b, 0); return b; }

    // ---- RC override / MANUAL_CONTROL (джойстик) ----
    readonly ushort[] ovr = new ushort[18];
    bool ovrActive, manualActive, ovrRelease; DateTime ovrStamp = DateTime.MinValue, ovrSent = DateTime.MinValue;
    short mx, my, mz, mr;

    public void SetOverride(ushort[] v)
    {
        lock (lk)
        {
            for (int i = 0; i < 16 && i < v.Length; i++) ovr[i] = v[i];
            ovr[16] = 65535; ovr[17] = 65535;
            ovrActive = true; manualActive = false; ovrStamp = DateTime.UtcNow;
        }
        PumpRc();
    }
    public void SetManual(short x, short y, short z, short r)
    {
        lock (lk) { mx = x; my = y; mz = z; mr = r; manualActive = true; ovrActive = false; ovrStamp = DateTime.UtcNow; }
        PumpRc();
    }
    public void StopRc() { lock (lk) { if (ovrActive) ovrRelease = true; ovrActive = false; manualActive = false; } PumpRc(); }

    void PumpRc()
    {
        bool release = false, send = false, manual = false; ushort[] o = null; short x = 0, y = 0, z = 0, r = 0;
        lock (lk)
        {
            var now = DateTime.UtcNow;
            // Захист: якщо клієнт замовк на 1 с, відпускаємо канали
            if ((ovrActive || manualActive) && (now - ovrStamp).TotalSeconds > 1) { if (ovrActive) ovrRelease = true; ovrActive = false; manualActive = false; }
            if (ovrRelease) { release = true; ovrRelease = false; }
            else if ((ovrActive || manualActive) && (now - ovrSent).TotalMilliseconds >= 100) { send = true; ovrSent = now; manual = manualActive; o = (ushort[])ovr.Clone(); x = mx; y = my; z = mz; r = mr; }
        }
        if (release) o = new ushort[18];
        if (release || (send && !manual))
        {
            var c = new mavlink_rc_channels_override_t
            {
                target_system = targetSys, target_component = targetComp,
                chan1_raw = o[0], chan2_raw = o[1], chan3_raw = o[2], chan4_raw = o[3], chan5_raw = o[4], chan6_raw = o[5], chan7_raw = o[6], chan8_raw = o[7],
                chan9_raw = o[8], chan10_raw = o[9], chan11_raw = o[10], chan12_raw = o[11], chan13_raw = o[12], chan14_raw = o[13], chan15_raw = o[14], chan16_raw = o[15],
                chan17_raw = o[16], chan18_raw = o[17]
            };
            Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.RC_CHANNELS_OVERRIDE, c, false, Link.GcsId, 190, 0));
        }
        else if (send && manual)
        {
            var mc = new mavlink_manual_control_t { target = targetSys, x = x, y = y, z = z, r = r, buttons = 0 };
            Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.MANUAL_CONTROL, mc, false, Link.GcsId, 190, 0));
        }
    }

    // ---- Лог, поля, tlog ----
    readonly System.Collections.Generic.Dictionary<string, (Type type, byte[] payload)> latest = new System.Collections.Generic.Dictionary<string, (Type, byte[])>();
    readonly System.Collections.Generic.List<object> logItems = new System.Collections.Generic.List<object>();
    int logSeq;
    DateTime lastTick = DateTime.MinValue, lastHomeReq = DateTime.MinValue;
    FileStream tlog; string tlogPath; int tlogWrites;
    bool replaying; CancellationTokenSource replayCts; double replayProgress; double replaySpeed = 1;
    /// Власна папка логів (tlog і Dataflash .bin), задана в налаштуваннях застосунку; порожньо = типова в Application Support.
    public static string LogRoot = "";
    static string SupportDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ArduTune");
    public static string LogsDir
    {
        get
        {
            var d = !string.IsNullOrEmpty(LogRoot) ? LogRoot : Path.Combine(SupportDir, "Logs");
            Directory.CreateDirectory(d); return d;
        }
    }

    public string LogJson() { lock (lk) return JsonSerializer.Serialize(new { seq = logSeq, items = logItems.ToArray() }); }

    static byte[] Payload(MAVLinkMessage m)
    {
        int hdr = m.ismavlink2 ? 10 : 6;
        var p = new byte[m.payloadlength];
        Array.Copy(m.buffer, hdr, p, 0, Math.Min(p.Length, Math.Max(0, m.buffer.Length - hdr)));
        return p;
    }

    /// Розбір полів вручну з байтів (рефлексія GetValue на packed-структурах дає SIGBUS на Apple Silicon).
    public string FieldsJson()
    {
        lock (lk)
        {
            var list = new System.Collections.Generic.List<object>();
            foreach (var kv in latest.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                var fields = kv.Value.type.GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);
                var src = kv.Value.payload;
                int off = 0;
                foreach (var f in fields)
                {
                    var ft = f.FieldType;
                    int n = 1;
                    var et = ft;
                    if (ft.IsArray)
                    {
                        et = ft.GetElementType();
                        var ma = (System.Runtime.InteropServices.MarshalAsAttribute)Attribute.GetCustomAttribute(f, typeof(System.Runtime.InteropServices.MarshalAsAttribute));
                        n = ma != null ? ma.SizeConst : 1;
                    }
                    int sz = et == typeof(byte) || et == typeof(sbyte) ? 1 : (et == typeof(short) || et == typeof(ushort)) ? 2 :
                             (et == typeof(int) || et == typeof(uint) || et == typeof(float)) ? 4 : (et == typeof(long) || et == typeof(ulong) || et == typeof(double)) ? 8 : 1;
                    if (et.IsEnum) sz = System.Runtime.InteropServices.Marshal.SizeOf(Enum.GetUnderlyingType(et));
                    var buf = new byte[sz * n];
                    if (off < src.Length) Array.Copy(src, off, buf, 0, Math.Min(buf.Length, src.Length - off));
                    off += sz * n;
                    string One(int i)
                    {
                        int o = i * sz; var t = et.IsEnum ? Enum.GetUnderlyingType(et) : et;
                        if (t == typeof(byte)) return buf[o].ToString();
                        if (t == typeof(sbyte)) return ((sbyte)buf[o]).ToString();
                        if (t == typeof(short)) return BitConverter.ToInt16(buf, o).ToString();
                        if (t == typeof(ushort)) return BitConverter.ToUInt16(buf, o).ToString();
                        if (t == typeof(int)) return BitConverter.ToInt32(buf, o).ToString();
                        if (t == typeof(uint)) return BitConverter.ToUInt32(buf, o).ToString();
                        if (t == typeof(long)) return BitConverter.ToInt64(buf, o).ToString();
                        if (t == typeof(ulong)) return BitConverter.ToUInt64(buf, o).ToString();
                        if (t == typeof(float)) return BitConverter.ToSingle(buf, o).ToString("0.#####", System.Globalization.CultureInfo.InvariantCulture);
                        if (t == typeof(double)) return BitConverter.ToDouble(buf, o).ToString("0.#####", System.Globalization.CultureInfo.InvariantCulture);
                        return "";
                    }
                    string str;
                    if (!ft.IsArray) str = One(0);
                    else if (et == typeof(byte) && buf.Length > 0 && buf.All(x => x == 0 || (x >= 32 && x < 127))) str = Encoding.ASCII.GetString(buf).TrimEnd('\0');
                    else str = string.Join(",", Enumerable.Range(0, Math.Min(n, 8)).Select(One));
                    list.Add(new { k = kv.Key + "." + f.Name, v = str });
                }
            }
            return JsonSerializer.Serialize(list);
        }
    }

    void StartRecording()
    {
        if (tlog != null || replaying) return;
        if (File.Exists(Path.Combine(SupportDir, "norecord"))) return;     // запис вимкнено в застосунку
        try
        {
            tlogPath = Path.Combine(LogsDir, DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss") + ".tlog");
            tlog = new FileStream(tlogPath, FileMode.Create, FileAccess.Write, FileShare.Read);
        }
        catch { tlog = null; tlogPath = null; }
    }
    void StopRecording()
    {
        var p = tlogPath;
        try { tlog?.Flush(); tlog?.Dispose(); } catch { }
        tlog = null; tlogPath = null;
        try { if (p != null && new FileInfo(p).Length < 1024) File.Delete(p); } catch { }      // порожні записи не лишаємо
    }
    public void RecordStop() { lock (lk) StopRecording(); }
    public void RecordStart() { lock (lk) { if (vtype != 0) StartRecording(); } }
    void Record(MAVLinkMessage pkt)
    {
        var f = tlog; if (f == null) return;
        try
        {
            long us = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds * 1000;
            var ts = new byte[8]; for (int i = 0; i < 8; i++) ts[i] = (byte)(us >> (56 - 8 * i));
            f.Write(ts, 0, 8); f.Write(pkt.buffer, 0, pkt.buffer.Length);
            if (++tlogWrites % 50 == 0) f.Flush();
        }
        catch { }
    }

    public bool Replay(string path, double speed)
    {
        lock (lk) { if (io != null) return false; }
        StopReplay();
        replayCts = new CancellationTokenSource(); var ct = replayCts.Token;
        lock (lk) { replaySpeed = Math.Clamp(speed, 0.25, 16); replayProgress = 0; replaying = true; }
        Task.Run(async () =>
        {
            try
            {
                var data = File.ReadAllBytes(path); int pos = 0; DateTime? prev = null;
                var epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
                while (pos + 9 < data.Length && !ct.IsCancellationRequested)
                {
                    long us = 0; for (int i = 0; i < 8; i++) us = (us << 8) | data[pos + i];
                    pos += 8;
                    int len; byte stx = data[pos];
                    if (stx == 0xFD) { int pl = data[pos + 1]; bool sg = (data[pos + 2] & 1) != 0; len = 10 + pl + 2 + (sg ? 13 : 0); }
                    else if (stx == 0xFE) { int pl = data[pos + 1]; len = 6 + pl + 2; }
                    else break;
                    if (pos + len > data.Length) break;
                    var buf = new byte[len]; Array.Copy(data, pos, buf, 0, len); pos += len;
                    var t = epoch.AddTicks(us * 10);
                    if (prev.HasValue)
                    {
                        var dt = (t - prev.Value).TotalMilliseconds / replaySpeed;
                        if (dt > 2) await Task.Delay((int)Math.Min(dt, 1500), ct);
                    }
                    prev = t;
                    try { Handle(new MAVLinkMessage(buf, t)); } catch { }
                    lock (lk) { replayProgress = (double)pos / data.Length; }
                }
            }
            catch { }
            finally { lock (lk) { replaying = false; replayProgress = replayCts != null && replayCts.IsCancellationRequested ? replayProgress : 1; } }
        });
        return true;
    }
    public void StopReplay() { try { replayCts?.Cancel(); } catch { } lock (lk) { replaying = false; } }

    // ---- Керування польотом ----
    public void Arm(bool on, bool force) => Cmd(MAV_CMD.COMPONENT_ARM_DISARM, on ? 1 : 0, force ? 21196 : 0);
    /// Команда з точними координатами (int32 ×1e7), як COMMAND_INT у Mission Planner.
    public void CmdInt(MAV_CMD cmd, double lat, double lon, float alt, byte frame, float p1 = 0, float p2 = 0, float p3 = 0, float p4 = 0)
    {
        var c = new mavlink_command_int_t
        {
            target_system = targetSys, target_component = targetComp, command = (ushort)cmd, frame = frame,
            param1 = p1, param2 = p2, param3 = p3, param4 = p4, x = (int)(lat * 1e7), y = (int)(lon * 1e7), z = alt
        };
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.COMMAND_INT, c, false, Link.GcsId, 190, 0));
    }
    public double GroundAmsl() { lock (lk) return T.altMsl - T.altRel; }
    public void SetMode(int mode) => Cmd(MAV_CMD.DO_SET_MODE, 1, mode);
    public void GoTo(double lat, double lon, float alt)
    {
        var g = new mavlink_set_position_target_global_int_t
        {
            target_system = targetSys, target_component = targetComp,
            coordinate_frame = (byte)MAV_FRAME.GLOBAL_RELATIVE_ALT_INT,
            type_mask = 0b0000111111111000,
            lat_int = (int)(lat * 1e7), lon_int = (int)(lon * 1e7), alt = alt
        };
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.SET_POSITION_TARGET_GLOBAL_INT, g, false, Link.GcsId, 190, 0));
    }

    // ---- Серво/RC/тести ----
    readonly ushort[] servoOut = new ushort[16];
    readonly ushort[] rcIn = new ushort[18];
    DateTime testEnabledUntil = DateTime.MinValue;
    public bool TestEnabled { get { lock (lk) return DateTime.UtcNow < testEnabledUntil; } }
    public void EnableTests(bool on) { lock (lk) { testEnabledUntil = on ? DateTime.UtcNow.AddMinutes(3) : DateTime.MinValue; } }
    public string IoJson() { lock (lk) return JsonSerializer.Serialize(new { servo = servoOut, rc = rcIn, testEnabled = DateTime.UtcNow < testEnabledUntil, armed = T.armed }); }
    public void MotorTest(int motor, float throttle, float timeout, int count, int order)
        => Cmd(MAV_CMD.DO_MOTOR_TEST, motor, 0, throttle, timeout, count, order);
    public void SetMsgInterval(int msgid, int hz) => Cmd(MAV_CMD.SET_MESSAGE_INTERVAL, msgid, 1_000_000f / hz);

    // ---- Команди та калібрування ----
    int accelPos; int accelSeq; string accelResult;
    int lastAckCmd; int lastAckResult; int ackSeq;
    int msgSeq; readonly System.Collections.Generic.List<string> msgs = new System.Collections.Generic.List<string>();
    // ---- Батареї за екземплярами (BATTERY_STATUS) ----
    class BattInfo { public int id; public double volt, amps, mah; public double? temp; public int pct; public DateTime stamp; }
    readonly System.Collections.Generic.Dictionary<int, BattInfo> batts = new System.Collections.Generic.Dictionary<int, BattInfo>();
    public string BatteriesJson()
    {
        lock (lk)
        {
            var now = DateTime.UtcNow;
            return JsonSerializer.Serialize(batts.Values.OrderBy(b => b.id).Select(b => new { b.id, b.volt, b.amps, b.mah, b.temp, b.pct, age = (now - b.stamp).TotalSeconds }));
        }
    }
    void ParseBatt(MAVLinkMessage m)
    {
        var p = Payload(m); if (p.Length < 36) Array.Resize(ref p, 36);
        double mv = 0; int n = 0;
        for (int i = 0; i < 10; i++) { var v = BitConverter.ToUInt16(p, 10 + i * 2); if (v != 65535) { mv += v; n++; } }
        var id = p[32];
        batts[id] = new BattInfo { id = id, volt = n > 0 ? mv / 1000.0 : 0, amps = BitConverter.ToInt16(p, 30) / 100.0, mah = BitConverter.ToInt32(p, 0), temp = BitConverter.ToInt16(p, 8) == short.MaxValue ? (double?)null : BitConverter.ToInt16(p, 8) / 100.0, pct = (sbyte)p[35], stamp = DateTime.UtcNow };
    }

    // ---- Компенсація завад від моторів (CompassMot) ----
    bool cmActive; DateTime cmStamp = DateTime.MinValue; int cmSeq;
    float cmCurrent, cmX, cmY, cmZ; ushort cmThrottle, cmInterference;
    public void CompassMotStart() { lock (lk) { cmActive = true; cmStamp = DateTime.MinValue; cmSeq = 0; cmThrottle = 0; cmInterference = 0; cmCurrent = 0; cmX = cmY = cmZ = 0; } Cmd(MAV_CMD.PREFLIGHT_CALIBRATION, 0, 0, 0, 0, 0, 1, 0); }
    public void CompassMotStop() { lock (lk) { cmActive = false; } Arm(false, true); }
    class MagInfo { public int id; public int pct; public int status; public int attempt; public int[] mask = new int[10]; public double fitness; public double x, y, z; public bool done; public int autosaved; }
    DateTime magStarted = DateTime.MinValue;
    readonly System.Collections.Generic.Dictionary<int, MagInfo> mags = new System.Collections.Generic.Dictionary<int, MagInfo>();
    /// Системний ID станції (GCS) у вихідних пакетах MAVLink; змінюється з налаштувань застосунку.
    public static byte GcsId = 255;
    public bool Armed { get { lock (lk) return T.armed; } }

    public void Cmd(MAV_CMD cmd, float p1 = 0, float p2 = 0, float p3 = 0, float p4 = 0, float p5 = 0, float p6 = 0, float p7 = 0)
    {
        var c = new mavlink_command_long_t { target_system = targetSys, target_component = targetComp, command = (ushort)cmd, confirmation = 0, param1 = p1, param2 = p2, param3 = p3, param4 = p4, param5 = p5, param6 = p6, param7 = p7 };
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.COMMAND_LONG, c, false, Link.GcsId, 190, 0));
    }

    public void AccelStart() { lock (lk) { accelPos = 0; accelResult = null; accelSeq++; } Cmd(MAV_CMD.PREFLIGHT_CALIBRATION, 0, 0, 0, 0, 1); }
    public void AccelConfirm(int pos) { lock (lk) { accelPos = 0; } Cmd(MAV_CMD.ACCELCAL_VEHICLE_POS, pos); }
    public void CalCancel() { lock (lk) { accelPos = 0; accelResult = null; magStarted = DateTime.MinValue; } Cmd(MAV_CMD.PREFLIGHT_CALIBRATION, 0, 0, 0, 0, 0); Cmd(MAV_CMD.DO_CANCEL_MAG_CAL, 0); }
    public void MagStart(int mask) { lock (lk) { mags.Clear(); magStarted = DateTime.UtcNow; } Cmd(MAV_CMD.DO_START_MAG_CAL, mask, 1, 0, 0, 0); }

    public string CalJson()
    {
        lock (lk)
        {
            return JsonSerializer.Serialize(new
            {
                accelPos, accelSeq, accelResult, ackCmd = lastAckCmd, ackResult = lastAckResult, ackSeq,
                mags = mags.Values.OrderBy(m => m.id).ToArray(),
                magElapsed = magStarted == DateTime.MinValue ? 0 : (DateTime.UtcNow - magStarted).TotalSeconds,
                compassMot = new { active = cmActive, seq = cmSeq, age = cmStamp == DateTime.MinValue ? -1.0 : (DateTime.UtcNow - cmStamp).TotalSeconds, throttle = (int)cmThrottle, current = cmCurrent, interference = (int)cmInterference, x = cmX, y = cmY, z = cmZ },
                msgSeq, msgs = msgs.ToArray()
            });
        }
    }

    public string ParamsJson()
    {
        lock (lk)
        {
            var items = ps.Values.OrderBy(x => x.n, StringComparer.Ordinal).Select(x => new { n = x.n, v = x.v, t = x.t });
            return JsonSerializer.Serialize(new { loading = pLoading, count = pCount, received = ps.Count, items });
        }
    }

    public void RefreshParams()
    {
        lock (lk) { ps.Clear(); pCount = 0; pLoading = true; lastParam = DateTime.UtcNow; retryRounds = 0; }
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.PARAM_REQUEST_LIST, new mavlink_param_request_list_t { target_system = targetSys, target_component = targetComp }, false, Link.GcsId, 190, 0));
    }

    public bool SetParam(string name, float value)
    {
        byte type;
        lock (lk) { if (!ps.TryGetValue(name, out var it)) return false; type = it.t; }
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.PARAM_SET, new mavlink_param_set_t { target_system = targetSys, target_component = targetComp, param_id = IdBytes(name), param_value = value, param_type = type }, false, Link.GcsId, 190, 0));
        return true;
    }

    void RetryMissing()
    {
        int[] missing;
        lock (lk)
        {
            if (!pLoading) return;
            if (pCount > 0 && ps.Count >= pCount) { pLoading = false; return; }
            if ((DateTime.UtcNow - lastParam).TotalSeconds < 1.5) return;
            retryRounds++;
            var have = new System.Collections.Generic.HashSet<int>(ps.Values.Select(x => x.idx));
            missing = Enumerable.Range(0, pCount).Where(i => !have.Contains(i)).Take(60).ToArray();
            if (pCount == 0) { missing = null; }
        }
        if (missing == null) { RefreshParams(); return; }
        Console.WriteLine($"[params] повторний запит {missing.Length} шт (раунд {retryRounds}): {string.Join(",", missing.Take(12))}");
        // Якщо індивідуальні запити не допомагають, повторюємо загальний запит списку (без очищення вже отриманого)
        if (retryRounds % 4 == 0)
            Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.PARAM_REQUEST_LIST, new mavlink_param_request_list_t { target_system = targetSys, target_component = targetComp }, false, Link.GcsId, 190, 0));
        foreach (var i in missing)
            Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.PARAM_REQUEST_READ, new mavlink_param_request_read_t { target_system = targetSys, target_component = targetComp, param_index = (short)i, param_id = new byte[16] }, false, Link.GcsId, 190, 0));
        lock (lk) { lastParam = DateTime.UtcNow; }
    }

    public string Snapshot()
    {
        lock (lk)
        {
            T.connected = (DateTime.UtcNow - lastHb).TotalSeconds < 3; T.booting = T.connected && Booting;
            T.metaSource = Meta.Source; T.recording = tlog != null; T.recordFile = tlogPath == null ? null : Path.GetFileName(tlogPath);
            T.linkType = cfg.type; T.linkError = linkError; T.linkState = userDisconnected ? "disconnected" : (io != null ? "open" : (linkConnecting ? "connecting" : "searching"));
            T.replaying = replaying; T.replayProgress = replayProgress; T.replaySpeed = replaySpeed;
            return JsonSerializer.Serialize(T);
        }
    }

    public static string[] Ports() =>
        Directory.GetFiles("/dev", "cu.*")
            .Where(p => p.Contains("usbmodem") || p.Contains("usbserial") || p.Contains("SLAB") || p.Contains("wchusb"))
            .OrderBy(p => p).ToArray();

    /// Усі послідовні порти (USB і Bluetooth), як у списку підключень Mission Planner.
    public static object[] AllPorts() =>
        Directory.GetFiles("/dev", "cu.*")
            .Where(p => !p.EndsWith("Bluetooth-Incoming-Port") && !p.EndsWith("debug-console"))
            .OrderBy(p => p)
            .Select(p => (object)new { path = p, usb = p.Contains("usb") || p.Contains("SLAB") || p.Contains("wch") }).ToArray();

    public void Connect(ConnCfg c) { lock (lk) { cfg = c; userDisconnected = false; linkError = null; } abort = true; }
    public void Disconnect() { lock (lk) { userDisconnected = true; linkError = null; } abort = true; }

    public async Task RunAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            ConnCfg c; bool off;
            lock (lk) { c = cfg; off = userDisconnected; }
            if (off) { lock (lk) { T.port = null; } await Task.Delay(300, ct); continue; }
            try
            {
                if (c.type == "auto")
                {
                    var ports = Ports();
                    if (ports.Length == 0) { lock (lk) { T.port = null; } await Task.Delay(1000, ct); continue; }
                    c = new ConnCfg { type = "serial", path = ports[0], baud = c.baud <= 0 ? 115200 : c.baud };
                }
                linkConnecting = true;
                abort = false;
                var (stream, desc) = await Transport.OpenAsync(c, ct);
                io = stream; linkConnecting = false;
                lock (lk) { T.port = desc; linkError = null; }
                Console.WriteLine("Connected to " + desc);
                await Loop(ct);
            }
            catch (Exception e) { lock (lk) { linkError = e.Message; } Console.WriteLine("Link: " + e.Message); }
            finally
            {
                linkConnecting = false;
                StopRecording(); apVer = null; HwReset(); Meta.ResetVersion(); lock (lk) { logItems.Clear(); msgStats.Clear(); }
                try { io?.Dispose(); } catch { }
                io = null; lastHb = DateTime.MinValue; hbSince = DateTime.MinValue; sysStatus = -1; autoRequested = false;
                lock (lk) { T.homeSet = false; ps.Clear(); pCount = 0; pLoading = false; T.port = null; }
            }
            await Task.Delay(c.type == "auto" ? 1000 : 1500, ct);
        }
    }

    async Task Loop(CancellationToken ct)
    {
        var parse = new MavlinkParse();
        var stream = io;
        var lastSend = DateTime.MinValue; bool streamsSet = false;
        while (!ct.IsCancellationRequested && !abort && !(io is QueueStream qd && qd.Dead))
        {
            PumpRc();
            if ((DateTime.UtcNow - lastSend).TotalSeconds >= 1)
            {
                lastSend = DateTime.UtcNow;
                var hb = new mavlink_heartbeat_t { type = (byte)MAV_TYPE.GCS, autopilot = (byte)MAV_AUTOPILOT.INVALID, mavlink_version = 3 };
                Send(parse.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.HEARTBEAT, hb, false, Link.GcsId, 190, 0));
                if ((T.connected || lastHb != DateTime.MinValue) && !Booting)
                {
                    if (!streamsSet) { RequestStreams(parse); SetMsgInterval(36, 10); SetMsgInterval(65, 10); SetMsgInterval(241, 2); SetMsgInterval(147, 2); SetMsgInterval(193, 2); SetMsgInterval(62, 5); streamsSet = true; }
                    if (!autoRequested) { autoRequested = true; RefreshParams(); }
                    RetryMissing();
                    if (!T.homeSet && (DateTime.UtcNow - lastHomeReq).TotalSeconds > 5) { lastHomeReq = DateTime.UtcNow; Cmd(MAV_CMD.REQUEST_MESSAGE, 242); }
                }
            }
            MAVLinkMessage pkt;
            try { pkt = parse.ReadPacket(stream); }
            catch (TimeoutException) { await Task.Delay(5, ct); continue; }
            if (pkt == null) { await Task.Delay(5, ct); continue; }
            Record(pkt);
            Handle(pkt);
        }
    }

    void Send(byte[] b) { lock (wl) { try { io?.Write(b, 0, b.Length); } catch { } } }

    void RequestStreams(MavlinkParse parse)
    {
        // Старий, але надійний спосіб для ArduPilot: 10 Гц для основних груп
        foreach (var s in new[] { MAV_DATA_STREAM.ALL })
        {
            var r = new mavlink_request_data_stream_t { target_system = targetSys, target_component = targetComp, req_stream_id = (byte)s, req_message_rate = 10, start_stop = 1 };
            Send(parse.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.REQUEST_DATA_STREAM, r, false, Link.GcsId, 190, 0));
        }
    }

    void Handle(MAVLinkMessage m)
    {
        Intercept(m);
        lock (lk)
        {
            count++;
            var now = DateTime.UtcNow;
            if ((now - rateT).TotalSeconds >= 1) { T.msgRate = count / (now - rateT).TotalSeconds; count = 0; rateT = now; }
            if (!(m.msgid == 0 && ((mavlink_heartbeat_t)m.data).type == (byte)MAV_TYPE.GCS))
            {
                var nm = ((MAVLINK_MSG_ID)m.msgid).ToString();
                latest[nm] = (m.data.GetType(), Payload(m));
                if (!msgStats.TryGetValue(nm, out var st)) msgStats[nm] = st = new MsgStat { id = (int)m.msgid, winStart = now };
                st.sys = m.sysid; st.comp = m.compid; st.count++; st.win++; st.last = now;
                var wd = (now - st.winStart).TotalSeconds;
                if (wd >= 1) { st.hz = st.win / wd; st.win = 0; st.winStart = now; }
            }
            if (lastTick != DateTime.MinValue && T.armed)
            {
                var dt = (now - lastTick).TotalSeconds; if (dt < 2) { T.timeInAir += dt; T.distTraveled += T.groundSpeed * dt; }
            }
            lastTick = now;
            switch ((MAVLINK_MSG_ID)m.msgid)
            {
                case MAVLINK_MSG_ID.HEARTBEAT:
                    var h = (mavlink_heartbeat_t)m.data;
                    if (h.type == (byte)MAV_TYPE.GCS) return;
                    if (lastHb == DateTime.MinValue) hbSince = now;
                    targetSys = m.sysid; targetComp = m.compid; vtype = h.type; lastHb = now; sysStatus = h.system_status;
                    T.vehicle = ((MAV_TYPE)h.type).ToString();
                    Meta.ForVehicle(T.vehicle);
                    T.mode = Mode.Name(h.type, h.custom_mode);
                    T.armed = (h.base_mode & (byte)MAV_MODE_FLAG.SAFETY_ARMED) != 0;
                    T.customMode = (int)h.custom_mode;
                    if (tlog == null && !replaying) StartRecording();
                    if (apVer == null && !Booting && (DateTime.UtcNow - lastApReq).TotalSeconds > 4) { lastApReq = DateTime.UtcNow; Cmd(MAV_CMD.REQUEST_MESSAGE, 148); }
                    break;
                case MAVLINK_MSG_ID.ATTITUDE:
                    var a = (mavlink_attitude_t)m.data;
                    T.roll = a.roll * 180 / Math.PI; T.pitch = a.pitch * 180 / Math.PI; T.yaw = a.yaw * 180 / Math.PI;
                    break;
                case MAVLINK_MSG_ID.GLOBAL_POSITION_INT:
                    var g = (mavlink_global_position_int_t)m.data;
                    T.lat = g.lat / 1e7; T.lon = g.lon / 1e7; T.altRel = g.relative_alt / 1000.0; T.altMsl = g.alt / 1000.0;
                    break;
                case MAVLINK_MSG_ID.VFR_HUD:
                    var v = (mavlink_vfr_hud_t)m.data;
                    T.groundSpeed = v.groundspeed; T.airSpeed = v.airspeed; T.heading = v.heading; T.climb = v.climb; T.throttle = v.throttle;
                    break;
                case MAVLINK_MSG_ID.SYS_STATUS:
                    var s = (mavlink_sys_status_t)m.data;
                    T.batteryV = s.voltage_battery / 1000.0; T.batteryA = s.current_battery / 100.0; T.batteryPct = s.battery_remaining;
                    T.gpsHealthy = (s.onboard_control_sensors_enabled & 32) != 0 && (s.onboard_control_sensors_health & 32) != 0;
                    T.visoPresent = (s.onboard_control_sensors_present & 128) != 0 && (s.onboard_control_sensors_enabled & 128) != 0;
                    T.visoHealthy = (s.onboard_control_sensors_health & 128) != 0;
                    break;
                case MAVLINK_MSG_ID.GPS_RAW_INT:
                    var gp = (mavlink_gps_raw_int_t)m.data;
                    T.gpsFix = gp.fix_type; T.sats = gp.satellites_visible; T.hdop = gp.eph / 100.0;
                    T.cog = gp.cog == 65535 ? -1 : gp.cog / 100.0;
                    break;
                case MAVLINK_MSG_ID.RAW_IMU:
                    {
                        var ri = (mavlink_raw_imu_t)m.data;
                        double mx = ri.xmag, my = ri.ymag, mz = ri.zmag;
                        if (Math.Abs(mx) + Math.Abs(my) + Math.Abs(mz) < 10) { T.magHdg = -1; }
                        else
                        {
                            double r = T.roll * Math.PI / 180, pt = T.pitch * Math.PI / 180;
                            double xh = mx * Math.Cos(pt) + my * Math.Sin(r) * Math.Sin(pt) + mz * Math.Cos(r) * Math.Sin(pt);
                            double yh = my * Math.Cos(r) - mz * Math.Sin(r);
                            double hd = Math.Atan2(-yh, xh) * 180 / Math.PI; if (hd < 0) hd += 360;
                            T.magHdg = hd;
                        }
                    }
                    break;
                case MAVLINK_MSG_ID.PARAM_VALUE:
                    var pv = (mavlink_param_value_t)m.data;
                    var pn = Id(pv.param_id);
                    pCount = pv.param_count; if (!ps.ContainsKey(pn)) lastParam = now;
                    ps[pn] = new PItem { n = pn, v = pv.param_value, t = pv.param_type, idx = pv.param_index };
                    if (ps.Count >= pCount) pLoading = false;
                    break;
                case MAVLINK_MSG_ID.STATUSTEXT:
                    var st = (mavlink_statustext_t)m.data;
                    T.lastText = Encoding.UTF8.GetString(st.text).TrimEnd('\0');
                    msgs.Add(T.lastText); msgSeq++; if (msgs.Count > 60) msgs.RemoveAt(0);
                    logItems.Add(new { t = DateTime.Now.ToString("HH:mm:ss"), sev = (int)st.severity, text = T.lastText }); logSeq++; if (logItems.Count > 300) logItems.RemoveAt(0);
                    break;
                case MAVLINK_MSG_ID.SERVO_OUTPUT_RAW:
                    var so = (mavlink_servo_output_raw_t)m.data;
                    servoOut[0] = so.servo1_raw; servoOut[1] = so.servo2_raw; servoOut[2] = so.servo3_raw; servoOut[3] = so.servo4_raw;
                    servoOut[4] = so.servo5_raw; servoOut[5] = so.servo6_raw; servoOut[6] = so.servo7_raw; servoOut[7] = so.servo8_raw;
                    servoOut[8] = so.servo9_raw; servoOut[9] = so.servo10_raw; servoOut[10] = so.servo11_raw; servoOut[11] = so.servo12_raw;
                    servoOut[12] = so.servo13_raw; servoOut[13] = so.servo14_raw; servoOut[14] = so.servo15_raw; servoOut[15] = so.servo16_raw;
                    break;
                case MAVLINK_MSG_ID.RC_CHANNELS:
                    var rc = (mavlink_rc_channels_t)m.data;
                    rcIn[0] = rc.chan1_raw; rcIn[1] = rc.chan2_raw; rcIn[2] = rc.chan3_raw; rcIn[3] = rc.chan4_raw; rcIn[4] = rc.chan5_raw; rcIn[5] = rc.chan6_raw;
                    rcIn[6] = rc.chan7_raw; rcIn[7] = rc.chan8_raw; rcIn[8] = rc.chan9_raw; rcIn[9] = rc.chan10_raw; rcIn[10] = rc.chan11_raw; rcIn[11] = rc.chan12_raw;
                    T.rssi = rc.rssi; rcIn[12] = rc.chan13_raw; rcIn[13] = rc.chan14_raw; rcIn[14] = rc.chan15_raw; rcIn[15] = rc.chan16_raw; rcIn[16] = rc.chan17_raw; rcIn[17] = rc.chan18_raw;
                    break;
                case MAVLINK_MSG_ID.VIBRATION:
                    var vb = (mavlink_vibration_t)m.data; T.vibeX = vb.vibration_x; T.vibeY = vb.vibration_y; T.vibeZ = vb.vibration_z; T.vibeClip0 = vb.clipping_0; T.vibeClip1 = vb.clipping_1; T.vibeClip2 = vb.clipping_2;
                    break;
                case MAVLINK_MSG_ID.NAV_CONTROLLER_OUTPUT:
                    var nc = (mavlink_nav_controller_output_t)m.data; T.navRoll = nc.nav_roll; T.navPitch = nc.nav_pitch; T.wpDist = nc.wp_dist;
                    break;
                case MAVLINK_MSG_ID.MISSION_CURRENT:
                    var mcur = (mavlink_mission_current_t)m.data; T.wpSeq = mcur.seq; T.wpTotal = mcur.total;
                    break;
                case MAVLINK_MSG_ID.MISSION_ITEM_REACHED:
                    T.wpReached = ((mavlink_mission_item_reached_t)m.data).seq;
                    break;
                case MAVLINK_MSG_ID.BATTERY_STATUS:
                    var bs = (mavlink_battery_status_t)m.data; if (bs.current_consumed >= 0 && bs.id == 0) T.mahUsed = bs.current_consumed;
                    ParseBatt(m);
                    break;
                case MAVLINK_MSG_ID.EKF_STATUS_REPORT:
                    var ek = (mavlink_ekf_status_report_t)m.data;
                    T.ekfFlags = ek.flags; T.ekfVelVar = ek.velocity_variance; T.ekfPosHVar = ek.pos_horiz_variance; T.ekfPosVVar = ek.pos_vert_variance; T.ekfCompassVar = ek.compass_variance; T.ekfTerrainVar = ek.terrain_alt_variance;
                    break;
                case MAVLINK_MSG_ID.HOME_POSITION:
                    var hp = (mavlink_home_position_t)m.data; T.homeLat = hp.latitude / 1e7; T.homeLon = hp.longitude / 1e7; T.homeSet = true;
                    break;
                case MAVLINK_MSG_ID.COMMAND_ACK:
                    var ack = (mavlink_command_ack_t)m.data;
                    lastAckCmd = ack.command; lastAckResult = ack.result; ackSeq++;
                    break;
                case MAVLINK_MSG_ID.COMMAND_LONG:
                    var cl = (mavlink_command_long_t)m.data;
                    if (cl.command == (ushort)MAV_CMD.ACCELCAL_VEHICLE_POS)
                    {
                        var pos = (int)cl.param1;
                        if (pos == 16777215) { accelResult = "success"; accelPos = 0; }
                        else if (pos == 16777216) { accelResult = "failed"; accelPos = 0; }
                        else accelPos = pos;
                    }
                    break;
                case MAVLINK_MSG_ID.COMPASSMOT_STATUS:
                    {
                        var p = Payload(m); if (p.Length < 20) Array.Resize(ref p, 20);
                        cmCurrent = BitConverter.ToSingle(p, 0); cmX = BitConverter.ToSingle(p, 4); cmY = BitConverter.ToSingle(p, 8); cmZ = BitConverter.ToSingle(p, 12);
                        cmThrottle = BitConverter.ToUInt16(p, 16); cmInterference = BitConverter.ToUInt16(p, 18);
                        cmStamp = now; cmSeq++;
                    }
                    break;
                case MAVLINK_MSG_ID.MAG_CAL_PROGRESS:
                    var mp = (mavlink_mag_cal_progress_t)m.data;
                    if (!mags.TryGetValue(mp.compass_id, out var mi)) mags[mp.compass_id] = mi = new MagInfo { id = mp.compass_id };
                    mi.pct = mp.completion_pct; mi.status = mp.cal_status; mi.attempt = mp.attempt;
                    if (mp.completion_mask != null) for (int k = 0; k < 10 && k < mp.completion_mask.Length; k++) mi.mask[k] = mp.completion_mask[k];
                    break;
                case MAVLINK_MSG_ID.MAG_CAL_REPORT:
                    var mr = (mavlink_mag_cal_report_t)m.data;
                    if (!mags.TryGetValue(mr.compass_id, out var mj)) mags[mr.compass_id] = mj = new MagInfo { id = mr.compass_id };
                    mj.status = mr.cal_status; mj.fitness = mr.fitness; mj.x = mr.ofs_x; mj.y = mr.ofs_y; mj.z = mr.ofs_z; mj.done = true; mj.autosaved = mr.autosaved; mj.pct = 100;
                    break;
            }
        }
    }
}

class Program
{
    static async Task Main(string[] args)
    {
        Link.LogRoot = Environment.GetEnvironmentVariable("ARDUTUNE_LOGDIR") ?? "";
        var link = new Link();
        var cts = new CancellationTokenSource();
        _ = Task.Run(() => link.RunAsync(cts.Token));

        var builder = WebApplication.CreateBuilder(args);
        builder.WebHost.UseUrls("http://127.0.0.1:14560");
        var app = builder.Build();
        // Захист локального API: випадковий токен запуску (передає застосунок), заборона запитів із браузера (Origin)
        // і перевірка Host проти DNS rebinding. Без токена в середовищі (ручний запуск, налагодження) токен не вимагається.
        var apiToken = Environment.GetEnvironmentVariable("ARDUTUNE_TOKEN");
        var tokenBytes = string.IsNullOrEmpty(apiToken) ? null : System.Text.Encoding.UTF8.GetBytes(apiToken);
        app.Use(async (ctx, next) =>
        {
            var host = ctx.Request.Host.Value ?? "";
            if (host != "127.0.0.1:14560" && host != "localhost:14560" && host != "[::1]:14560") { ctx.Response.StatusCode = 403; return; }
            if (ctx.Request.Headers.ContainsKey("Origin")) { ctx.Response.StatusCode = 403; return; }
            if (tokenBytes != null)
            {
                var got = System.Text.Encoding.UTF8.GetBytes(ctx.Request.Headers["X-ArduTune-Token"].ToString());
                if (got.Length != tokenBytes.Length || !System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(got, tokenBytes)) { ctx.Response.StatusCode = 401; return; }
            }
            await next();
        });
        app.UseWebSockets();
        app.MapGet("/ports", () => Results.Json(Link.AllPorts()));
        app.MapPost("/connect", (string type, string? path, int? baud, string? host, int? port) =>
        {
            if (type != "auto" && type != "serial" && string.IsNullOrWhiteSpace(path) && string.IsNullOrWhiteSpace(host) && type != "udp") return Results.BadRequest(new { error = "host" });
            link.Connect(new ConnCfg { type = type, path = path, baud = baud ?? 115200, host = host, port = port ?? 0 });
            return Results.Ok();
        });
        app.MapPost("/disconnect", () => { link.Disconnect(); return Results.Ok(); });
        _ = Task.Run(Meta.LoadAsync);
        // Усі небезпечні команди відхиляються, якщо апарат ARMED.
        IResult Guard(Action a) { if (link.Armed) return Results.Json(new { error = "armed" }, statusCode: 409); a(); return Results.Ok(); }
        app.MapPost("/rc/override", (HttpContext ctx) =>
        {
            var v = new ushort[16];
            for (int i = 0; i < 16; i++) v[i] = ushort.TryParse(ctx.Request.Query["c" + (i + 1)], out var n) ? n : (ushort)65535;
            link.SetOverride(v); return Results.Ok();
        });
        app.MapPost("/rc/manual", (short x, short y, short z, short r) => { link.SetManual(x, y, z, r); return Results.Ok(); });
        app.MapPost("/rc/stop", () => { link.StopRc(); return Results.Ok(); });
        // ---- Файли: MAVFTP (скрипти) і Dataflash-логи ----
        async Task<IResult> FileOp(Func<IResult> f)
        {
            try { return await Task.Run(f); }
            catch (FtpException e) { return Results.Json(new { error = e.Message, code = e.Code }, statusCode: e.Code == 10 ? 404 : 502); }
            catch (Exception e) { return Results.Json(new { error = e.Message }, statusCode: 500); }
        }
        app.MapGet("/ftp/list", (string path) => FileOp(() => Results.Json(link.FtpList(path))));
        app.MapGet("/ftp/read", (string path) => FileOp(() => Results.Bytes(link.FtpReadFast(path), "application/octet-stream")));
        app.MapPost("/ftp/get", (string path, string dest) => link.FtpGetStart(path, dest) ? Results.Ok() : Results.Json(new { error = "busy" }, statusCode: 409));
        app.MapGet("/ftp/get/status", () => Results.Json(link.FtpGetState()));
        app.MapPost("/ftp/get/cancel", () => { link.FtpGetCancel(); return Results.Ok(); });
        app.MapPost("/ftp/write", async (HttpContext ctx, string path) =>
        {
            if (link.Armed) return Results.Json(new { error = "armed" }, statusCode: 409);
            using var ms = new MemoryStream(); await ctx.Request.Body.CopyToAsync(ms); var data = ms.ToArray();
            return await FileOp(() => { link.FtpWrite(path, data); return Results.Ok(); });
        });
        app.MapPost("/ftp/delete", (string path) => link.Armed ? Task.FromResult(Results.Json(new { error = "armed" }, statusCode: 409)) : FileOp(() => { link.FtpRemove(path); return Results.Ok(); }));
        app.MapPost("/ftp/mkdir", (string path) => FileOp(() => { link.FtpMkdir(path); return Results.Ok(); }));
        app.MapPost("/ftp/rename", (string from, string to) => FileOp(() => { link.FtpRename(from, to); return Results.Ok(); }));
        app.MapPost("/scripting/restart", () => { link.Cmd(MAV_CMD.SCRIPTING, 3); return Results.Ok(); });
        app.MapGet("/dflogs/list", () => FileOp(() =>
        {
            var l = link.DfList();
            return Results.Json(l.Select(e => new { e.id, e.size, time = e.timeUtc, local = Directory.GetFiles(Link.DfDir, $"*_{e.id:000}_*.bin").FirstOrDefault() }));
        }));
        app.MapPost("/dflogs/download", (int id) => link.Armed ? Results.Json(new { error = "armed" }, statusCode: 409) : (link.DfDownload(id) ? Results.Ok() : Results.Json(new { error = "busy" }, statusCode: 409)));
        app.MapGet("/dflogs/status", () => Results.Json(link.DfState));
        app.MapPost("/dflogs/cancel", () => { link.DfCancel(); return Results.Ok(); });
        app.MapPost("/dflogs/erase", () => link.Armed ? Results.Json(new { error = "armed" }, statusCode: 409) : Guard(link.DfErase));
        app.MapGet("/dflogs/local", () => Results.Json(new DirectoryInfo(Link.DfDir).GetFiles("*.bin").OrderByDescending(f => f.LastWriteTime)
            .Select(f => new { name = f.Name, path = f.FullName, size = f.Length, date = f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") })));
        app.MapGet("/log", () => Results.Text(link.LogJson(), "application/json"));
        app.MapGet("/fields", () => Results.Text(link.FieldsJson(), "application/json"));
        app.MapGet("/logs", () => Results.Json(new DirectoryInfo(Link.LogsDir).GetFiles("*.tlog").OrderByDescending(f => f.LastWriteTime)
            .Select(f => new { name = f.Name, path = f.FullName, size = f.Length, date = f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") })));
        app.MapGet("/mission/download", (int? type) => FileOp(() => Results.Json(link.MissionDownload((byte)(type ?? 0)))));
        app.MapPost("/mission/upload", async (HttpContext ctx, int? type) =>
        {
            using var rd = new StreamReader(ctx.Request.Body); var body = await rd.ReadToEndAsync();
            System.Collections.Generic.List<MItem> items;
            try { items = JsonSerializer.Deserialize<System.Collections.Generic.List<MItem>>(body, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }); }
            catch { return Results.Json(new { error = "Некоректні дані місії" }, statusCode: 400); }
            if (items == null) return Results.Json(new { error = "Порожня місія" }, statusCode: 400);
            return await FileOp(() => { if (items.Count == 0) link.MissionClear((byte)(type ?? 0)); else link.MissionUpload(items, (byte)(type ?? 0)); return Results.Ok(); });
        });
        app.MapPost("/mission/clear", (int? type) => FileOp(() => { link.MissionClear((byte)(type ?? 0)); return Results.Ok(); }));
        app.MapPost("/mission/current", (int seq) => { link.MissionSetCurrent(seq); return Results.Ok(); });
        app.MapGet("/autopilot", () => Task.Run(() => { var o = link.ApVersion(); return o == null ? Results.Json(new { error = "Автопілот не відповів на запит версії" }, statusCode: 504) : Results.Json(o); }));
        app.MapGet("/msgstats", () => Results.Json(link.MsgStatsList()));
        app.MapPost("/msgstats/reset", () => { link.MsgStatsReset(); return Results.Ok(); });
        app.MapGet("/adsb", () => Results.Json(link.AdsbList()));
        app.MapGet("/board", () => Task.Run(() => Results.Json(link.UsbBoards())));
        app.MapGet("/rangefinders", () => Results.Json(link.RangeList()));
        app.MapPost("/settings/logdir", (string? path) =>
        {
            var p = (path ?? "").Trim();
            if (p.Length > 0) { try { Directory.CreateDirectory(p); } catch { return Results.BadRequest(new { error = "path" }); } }
            Link.LogRoot = p; return Results.Ok();
        });
        app.MapPost("/settings/gcsid", (int id) => { if (id < 1 || id > 255) return Results.BadRequest(); Link.GcsId = (byte)id; return Results.Ok(); });
        app.MapPost("/msg/interval", (int id, int hz) => { link.SetMsgInterval(id, Math.Max(1, hz)); return Results.Ok(); });
        app.MapPost("/cmd/mount", (float pitch, float roll, float yaw) => { link.Cmd(MAV_CMD.DO_MOUNT_CONTROL, pitch, roll, yaw, 0, 0, 0, 2); return Results.Ok(); });
        app.MapPost("/cmd/mountmode", (int mode) => { link.Cmd(MAV_CMD.DO_MOUNT_CONFIGURE, mode); return Results.Ok(); });
        app.MapPost("/dronecan/start", (int bus) => { link.DcStart(bus); return Results.Ok(); });
        app.MapPost("/dronecan/stop", () => { link.DcStop(); return Results.Ok(); });
        app.MapGet("/dronecan", () => Results.Json(link.DcState()));
        app.MapPost("/dronecan/params/read", (int node) => link.DcReadParams(node) ? Results.Ok() : Results.Json(new { error = "busy" }, statusCode: 409));
        app.MapGet("/dronecan/params", (int node) => Results.Json(link.DcParams(node)));
        app.MapGet("/fw/manifest", async (bool? force) => { try { return Results.Text(await Link.FwManifest(force ?? false), "application/json"); } catch (Exception e) { return Results.Json(new { error = "Каталог недоступний: " + e.Message }, statusCode: 502); } });
        app.MapGet("/fw/versions", async (string vehicle, string platform) => { try { return Results.Text(await Link.FwVersions(vehicle, platform), "application/json"); } catch (Exception e) { return Results.Json(new { error = e.Message }, statusCode: 502); } });
        app.MapPost("/fw/download", async (string url) => { try { var p = await Link.FwDownload(url); return Results.Json(Link.FwInspect(p)); } catch (Exception e) { return Results.Json(new { error = e.Message }, statusCode: 502); } });
        app.MapGet("/fw/inspect", (string path) => { try { return Results.Json(Link.FwInspect(path)); } catch (Exception e) { return Results.Json(new { error = e.Message }, statusCode: 400); } });
        app.MapPost("/fw/flash", (string path, string? port, bool? force) => link.Armed ? Results.Json(new { error = "armed" }, statusCode: 409) : (link.FwStart(path, port ?? "", force ?? false) ? Results.Ok() : Results.Json(new { error = "Прошивання вже виконується" }, statusCode: 409)));
        app.MapPost("/fw/cancel", () => { link.FwCancel(); return Results.Ok(); });
        app.MapGet("/fw/status", () => Results.Json(link.FwState()));
        app.MapGet("/fw/ports", () => Results.Json(Link.UsbPorts()));
        app.MapPost("/record/stop", () => { link.RecordStop(); return Results.Ok(); });
        app.MapPost("/record/start", () => { link.RecordStart(); return Results.Ok(); });
        app.MapGet("/tlog/convert", (string path) => { try { return Results.Json(new { path = Link.TlogConvert(path) }); } catch (Exception e) { return Results.Json(new { error = e.Message }, statusCode: 500); } });
        app.MapPost("/replay/start", (string path, double speed) => link.Replay(path, speed) ? Results.Ok() : Results.Json(new { error = "connected" }, statusCode: 409));
        app.MapPost("/replay/stop", () => { link.StopReplay(); return Results.Ok(); });
        app.MapPost("/cmd/arm", (bool? force) => { link.Arm(true, force ?? false); return Results.Ok(); });
        app.MapPost("/cmd/disarm", (bool? force) => { link.Arm(false, force ?? false); return Results.Ok(); });
        app.MapPost("/cmd/mode", (int m) => { link.SetMode(m); return Results.Ok(); });
        app.MapPost("/cmd/takeoff", (float alt) => { link.Cmd(MAV_CMD.TAKEOFF, 0, 0, 0, float.NaN, float.NaN, float.NaN, alt); return Results.Ok(); });
        app.MapPost("/cmd/land", () => { link.Cmd(MAV_CMD.LAND); return Results.Ok(); });
        app.MapPost("/cmd/rtl", () => { link.Cmd(MAV_CMD.RETURN_TO_LAUNCH); return Results.Ok(); });
        app.MapPost("/cmd/speed", (float v) => { link.Cmd(MAV_CMD.DO_CHANGE_SPEED, 1, v, -1); return Results.Ok(); });
        app.MapPost("/cmd/alt", (float v) => { link.Cmd(MAV_CMD.DO_CHANGE_ALTITUDE, v, 3); return Results.Ok(); });
        app.MapPost("/cmd/home", () => { link.Cmd(MAV_CMD.DO_SET_HOME, 1); return Results.Ok(); });
        app.MapPost("/cmd/relay", (int n, int state) => { link.Cmd(MAV_CMD.DO_SET_RELAY, n, state); return Results.Ok(); });
        app.MapPost("/cmd/aux", (int fn, int pos) => { link.Cmd(MAV_CMD.DO_AUX_FUNCTION, fn, pos); return Results.Ok(); });
        app.MapPost("/cmd/roi", (double lat, double lon, float alt) => { link.CmdInt(MAV_CMD.DO_SET_ROI_LOCATION, lat, lon, alt, (byte)MAV_FRAME.GLOBAL_RELATIVE_ALT_INT); return Results.Ok(); });
        app.MapPost("/cmd/roinone", () => { link.Cmd(MAV_CMD.DO_SET_ROI_NONE); return Results.Ok(); });
        app.MapPost("/cmd/camtrigger", () => { link.Cmd(MAV_CMD.DO_DIGICAM_CONTROL, 0, 0, 0, 0, 1); return Results.Ok(); });
        app.MapPost("/cmd/sethome", (double lat, double lon) => { link.CmdInt(MAV_CMD.DO_SET_HOME, lat, lon, (float)link.GroundAmsl(), (byte)MAV_FRAME.GLOBAL, 0); return Results.Ok(); });
        app.MapPost("/cmd/goto", (double lat, double lon, float alt) => { link.GoTo(lat, lon, alt); return Results.Ok(); });
        app.MapGet("/io", () => Results.Text(link.IoJson(), "application/json"));
        // Тести моторів/серво: окремий дозвіл (діє 3 хв), тільки при DISARMED, жорсткі обмеження.
        app.MapPost("/test/enable", () => Guard(() => link.EnableTests(true)));
        app.MapPost("/test/disable", () => { link.EnableTests(false); return Results.Ok(); });
        IResult TestGuard(Action a) => Guard(a);
        app.MapPost("/motor/test", (int motor, float throttle, float timeout, int count, int order) =>
            TestGuard(() => link.MotorTest(Math.Clamp(motor, 1, 12), Math.Clamp(throttle, 0f, 30f), Math.Clamp(timeout, 0.5f, 10f), Math.Clamp(count, 0, 12), order == 2 ? 2 : 1)));
        app.MapPost("/motor/stop", () => { link.MotorTest(1, 0, 0.1f, 0, 1); return Results.Ok(); });
        app.MapPost("/servo/test", (int channel, int pwm) =>
            TestGuard(() => link.Cmd(MAV_CMD.DO_SET_SERVO, Math.Clamp(channel, 1, 16), Math.Clamp(pwm, 800, 2200))));
        app.MapGet("/cal", () => Results.Text(link.CalJson(), "application/json"));
        app.MapPost("/reboot", () => Guard(() => link.Cmd(MAV_CMD.PREFLIGHT_REBOOT_SHUTDOWN, 1)));
        app.MapPost("/cal/accel/start", () => Guard(link.AccelStart));
        app.MapPost("/cal/accel/pos", (int pos) => Guard(() => link.AccelConfirm(pos)));
        app.MapPost("/cal/cancel", () => { link.CalCancel(); return Results.Ok(); });
        app.MapPost("/cal/level", () => Guard(() => link.Cmd(MAV_CMD.PREFLIGHT_CALIBRATION, 0, 0, 0, 0, 2)));
        app.MapPost("/cal/gyro", () => Guard(() => link.Cmd(MAV_CMD.PREFLIGHT_CALIBRATION, 1)));
        app.MapPost("/cal/baro", () => Guard(() => link.Cmd(MAV_CMD.PREFLIGHT_CALIBRATION, 0, 0, 1)));
        app.MapPost("/cal/mag/start", (int? mask) => Guard(() => link.MagStart(mask ?? 0)));
        app.MapPost("/cal/mag/fixedyaw", (float yaw, int mask, float lat, float lon) => Guard(() => link.Cmd(MAV_CMD.FIXED_MAG_CAL_YAW, yaw, mask, lat, lon)));
        app.MapPost("/cal/compassmot/start", () => Guard(link.CompassMotStart));
        app.MapPost("/cal/compassmot/stop", () => { link.CompassMotStop(); return Results.Ok(); });
        app.MapPost("/cal/mag/accept", () => Guard(() => link.Cmd(MAV_CMD.DO_ACCEPT_MAG_CAL, 0)));
        app.MapGet("/params", () => Results.Text(link.ParamsJson(), "application/json"));
        app.MapGet("/batteries", () => Results.Text(link.BatteriesJson(), "application/json"));
        app.MapGet("/meta", () => Results.Text(Meta.Json, "application/json"));
        app.MapGet("/meta/vehicle", () => Results.Json(new { dir = Meta.Dir, status = Meta.Status, source = Meta.Source }));
        app.MapPost("/meta/select", (string dir) => Meta.ForDir(dir) ? Results.Ok() : Results.BadRequest());
        app.MapPost("/params/refresh", () => { link.RefreshParams(); return Results.Ok(); });
        app.MapPost("/params/set", (string name, float value) => link.SetParam(name, value) ? Results.Ok() : Results.NotFound());
        app.MapGet("/state", () => Results.Text(link.Snapshot(), "application/json"));
        app.Map("/ws", async (HttpContext ctx) =>
        {
            if (!ctx.WebSockets.IsWebSocketRequest) { ctx.Response.StatusCode = 400; return; }
            using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
            while (ws.State == WebSocketState.Open)
            {
                var bytes = Encoding.UTF8.GetBytes(link.Snapshot());
                await ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
                await Task.Delay(100);
            }
        });
        await app.RunAsync();
        cts.Cancel();
    }
}
