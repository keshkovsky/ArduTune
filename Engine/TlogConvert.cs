using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using static MAVLink;

// Перетворення tlog (запис MAVLink) у бінарний формат, який читає переглядач логів застосунку:
// записи 0xA3 0x95 <тип> ... , опис типів: «довгий FMT» (тип 127) з довгими іменами. Усі числа як double.
partial class Link
{
    sealed class Col { public string Name = ""; public int Off; public Type T = typeof(byte); public double Scale = 1; }
    sealed class Spec { public byte Type; public List<Col> Cols = new List<Col>(); public int Length => 3 + 8 + 8 * Cols.Count; }
    sealed class Lay { public string Name = ""; public int Off, N; public Type Et = typeof(byte); public bool Arr; }

    static readonly Dictionary<Type, List<Lay>> layouts = new Dictionary<Type, List<Lay>>();
    static readonly Dictionary<string, double> scales = new Dictionary<string, double>
    {
        ["GLOBAL_POSITION_INT.lat"] = 1e-7, ["GLOBAL_POSITION_INT.lon"] = 1e-7, ["GLOBAL_POSITION_INT.alt"] = 1e-3, ["GLOBAL_POSITION_INT.relative_alt"] = 1e-3,
        ["GLOBAL_POSITION_INT.vx"] = 0.01, ["GLOBAL_POSITION_INT.vy"] = 0.01, ["GLOBAL_POSITION_INT.vz"] = 0.01, ["GLOBAL_POSITION_INT.hdg"] = 0.01,
        ["GPS_RAW_INT.lat"] = 1e-7, ["GPS_RAW_INT.lon"] = 1e-7, ["GPS_RAW_INT.alt"] = 1e-3, ["GPS_RAW_INT.eph"] = 0.01, ["GPS_RAW_INT.epv"] = 0.01, ["GPS_RAW_INT.vel"] = 0.01, ["GPS_RAW_INT.cog"] = 0.01,
        ["ATTITUDE.roll"] = 180 / Math.PI, ["ATTITUDE.pitch"] = 180 / Math.PI, ["ATTITUDE.yaw"] = 180 / Math.PI,
        ["ATTITUDE.rollspeed"] = 180 / Math.PI, ["ATTITUDE.pitchspeed"] = 180 / Math.PI, ["ATTITUDE.yawspeed"] = 180 / Math.PI,
        ["SYS_STATUS.voltage_battery"] = 0.001, ["SYS_STATUS.current_battery"] = 0.01,
        ["BATTERY_STATUS.current_battery"] = 0.01,
    };

    static List<Lay> Layout(Type t)
    {
        lock (layouts)
        {
            if (layouts.TryGetValue(t, out var l)) return l;
            l = new List<Lay>(); int off = 0;
            foreach (var f in t.GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance))
            {
                var ft = f.FieldType; var et = ft; int n = 1;
                if (ft.IsArray)
                {
                    et = ft.GetElementType();
                    var ma = (System.Runtime.InteropServices.MarshalAsAttribute)Attribute.GetCustomAttribute(f, typeof(System.Runtime.InteropServices.MarshalAsAttribute));
                    n = ma != null ? ma.SizeConst : 1;
                }
                var ut = et.IsEnum ? Enum.GetUnderlyingType(et) : et;
                int sz = ut == typeof(byte) || ut == typeof(sbyte) ? 1 : (ut == typeof(short) || ut == typeof(ushort)) ? 2 :
                         (ut == typeof(int) || ut == typeof(uint) || ut == typeof(float)) ? 4 : (ut == typeof(long) || ut == typeof(ulong) || ut == typeof(double)) ? 8 : 1;
                l.Add(new Lay { Name = f.Name, Off = off, N = n, Et = ut, Arr = ft.IsArray });
                off += sz * n;
            }
            layouts[t] = l; return l;
        }
    }

    static int SizeOf(Type t) => t == typeof(byte) || t == typeof(sbyte) ? 1 : (t == typeof(short) || t == typeof(ushort)) ? 2 :
                                 (t == typeof(int) || t == typeof(uint) || t == typeof(float)) ? 4 : 8;

    static double ReadNum(byte[] p, int o, Type t)
    {
        int sz = SizeOf(t);
        if (o < 0 || o + sz > p.Length) { var b = new byte[8]; if (o >= 0 && o < p.Length) Array.Copy(p, o, b, 0, p.Length - o); return Conv(b, 0, t); }
        return Conv(p, o, t);
    }
    static double Conv(byte[] b, int o, Type t)
    {
        if (t == typeof(byte)) return b[o];
        if (t == typeof(sbyte)) return (sbyte)b[o];
        if (t == typeof(short)) return BitConverter.ToInt16(b, o);
        if (t == typeof(ushort)) return BitConverter.ToUInt16(b, o);
        if (t == typeof(int)) return BitConverter.ToInt32(b, o);
        if (t == typeof(uint)) return BitConverter.ToUInt32(b, o);
        if (t == typeof(long)) return BitConverter.ToInt64(b, o);
        if (t == typeof(ulong)) return BitConverter.ToUInt64(b, o);
        if (t == typeof(float)) return BitConverter.ToSingle(b, o);
        if (t == typeof(double)) return BitConverter.ToDouble(b, o);
        return 0;
    }

    static double Num(List<Lay> lay, byte[] p, string name)
    {
        var f = lay.FirstOrDefault(x => x.Name == name);
        return f == null ? 0 : ReadNum(p, f.Off, f.Et);
    }
    static string Str(List<Lay> lay, byte[] p, string name)
    {
        var f = lay.FirstOrDefault(x => x.Name == name);
        if (f == null) return "";
        int n = Math.Max(0, Math.Min(f.N, p.Length - f.Off)); if (n <= 0) return "";
        var s = Encoding.UTF8.GetString(p, f.Off, n); int z = s.IndexOf('\0'); return z >= 0 ? s.Substring(0, z) : s;
    }

    const string Ver = "v2";

    /// Повертає шлях до згенерованого .bin (кеш у ~/Library/Application Support/ArduTune/TlogView).
    public static string TlogConvert(string path)
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ArduTune", "TlogView");
        Directory.CreateDirectory(dir);
        var outPath = Path.Combine(dir, Path.GetFileNameWithoutExtension(path) + "." + Ver + ".bin");
        var fi = new FileInfo(path);
        if (File.Exists(outPath) && File.GetLastWriteTimeUtc(outPath) >= fi.LastWriteTimeUtc) return outPath;

        var data = File.ReadAllBytes(path); int pos = 0;
        var epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var specs = new Dictionary<string, Spec>(); byte next = 129;
        var ms = new MemoryStream(); var body = new MemoryStream();
        long? first = null; long lastUs = 0;
        int lastMode = -1; bool lastArmed = false; bool haveHb = false;

        Spec Make(string name, params string[] cols)
        {
            var s = new Spec { Type = next++ };
            foreach (var c in cols) s.Cols.Add(new Col { Name = c });
            specs[name] = s; return s;
        }
        void Rec(Spec s, long t, params double[] v)
        {
            body.WriteByte(0xA3); body.WriteByte(0x95); body.WriteByte(s.Type);
            body.Write(BitConverter.GetBytes((ulong)t), 0, 8);
            for (int i = 0; i < s.Cols.Count; i++) body.Write(BitConverter.GetBytes(i < v.Length ? v[i] : 0.0), 0, 8);
        }
        void RecMsg(long t, string text)
        {
            if (!specs.TryGetValue("MSG", out var s)) { s = new Spec { Type = next++ }; specs["MSG"] = s; }
            body.WriteByte(0xA3); body.WriteByte(0x95); body.WriteByte(s.Type);
            body.Write(BitConverter.GetBytes((ulong)t), 0, 8);
            var b = new byte[64]; var tb = Encoding.UTF8.GetBytes(text); Array.Copy(tb, b, Math.Min(63, tb.Length)); body.Write(b, 0, 64);
        }
        void RecParm(long t, string name, double val)
        {
            if (!specs.TryGetValue("PARM", out var s)) { s = new Spec { Type = next++ }; specs["PARM"] = s; }
            body.WriteByte(0xA3); body.WriteByte(0x95); body.WriteByte(s.Type);
            body.Write(BitConverter.GetBytes((ulong)t), 0, 8);
            var b = new byte[16]; var tb = Encoding.ASCII.GetBytes(name); Array.Copy(tb, b, Math.Min(16, tb.Length)); body.Write(b, 0, 16);
            body.Write(BitConverter.GetBytes(val), 0, 8);
        }

        while (pos + 9 < data.Length)
        {
            long us = 0; for (int i = 0; i < 8; i++) us = (us << 8) | data[pos + i];
            pos += 8;
            int len; byte stx = data[pos];
            if (stx == 0xFD) { int pl = data[pos + 1]; bool sg = (data[pos + 2] & 1) != 0; len = 10 + pl + 2 + (sg ? 13 : 0); }
            else if (stx == 0xFE) { int pl = data[pos + 1]; len = 6 + pl + 2; }
            else break;
            if (pos + len > data.Length) break;
            var buf = new byte[len]; Array.Copy(data, pos, buf, 0, len); pos += len;
            first ??= us;
            long t = us - first.Value + 1; lastUs = t;
            MAVLinkMessage m;
            try { m = new MAVLinkMessage(buf, epoch.AddTicks(us * 10)); } catch { continue; }
            if (m.data == null) continue;
            var name = ((MAVLINK_MSG_ID)m.msgid).ToString();
            if (name.Length == 0 || char.IsDigit(name[0])) continue;
            var type = m.data.GetType(); var lay = Layout(type); var p = Payload(m);

            if (!specs.TryGetValue(name, out var sp))
            {
                sp = new Spec { Type = next++ };
                foreach (var f in lay)
                {
                    if (sp.Cols.Count >= 22) break;
                    if (f.Arr && f.Et == typeof(byte)) continue;                       // рядки й службові масиви
                    if (f.Arr) for (int i = 0; i < Math.Min(f.N, 8) && sp.Cols.Count < 22; i++)
                            sp.Cols.Add(new Col { Name = f.Name + "_" + i, Off = f.Off + i * SizeOf(f.Et), T = f.Et, Scale = scales.GetValueOrDefault(name + "." + f.Name, 1) });
                    else sp.Cols.Add(new Col { Name = f.Name, Off = f.Off, T = f.Et, Scale = scales.GetValueOrDefault(name + "." + f.Name, 1) });
                }
                specs[name] = sp;
            }
            var vals = new double[sp.Cols.Count];
            for (int i = 0; i < vals.Length; i++) vals[i] = ReadNum(p, sp.Cols[i].Off, sp.Cols[i].T) * sp.Cols[i].Scale;
            Rec(sp, t, vals);

            switch ((MAVLINK_MSG_ID)m.msgid)
            {
                case MAVLINK_MSG_ID.STATUSTEXT: { var tx = Str(lay, p, "text"); if (tx.Length > 0) RecMsg(t, tx); break; }
                case MAVLINK_MSG_ID.PARAM_VALUE: RecParm(t, Str(lay, p, "param_id"), Num(lay, p, "param_value")); break;
                case MAVLINK_MSG_ID.GPS_RAW_INT:
                {
                    if (!specs.TryGetValue("GPS", out var g)) g = Make("GPS", "Status", "Lat", "Lng", "Alt", "Spd", "NSats");
                    Rec(g, t, Num(lay, p, "fix_type"), Num(lay, p, "lat") * 1e-7, Num(lay, p, "lon") * 1e-7, Num(lay, p, "alt") * 1e-3, Num(lay, p, "vel") * 0.01, Num(lay, p, "satellites_visible"));
                    break;
                }
                case MAVLINK_MSG_ID.HEARTBEAT:
                {
                    int vt = (int)Num(lay, p, "type"); if (vt == (int)MAV_TYPE.GCS) break;
                    int cm = (int)(uint)Num(lay, p, "custom_mode"); bool armed = ((int)Num(lay, p, "base_mode") & (int)MAV_MODE_FLAG.SAFETY_ARMED) != 0;
                    if (haveHb && cm != lastMode) RecMsg(t, "Режим: " + Mode.Name((byte)vt, (uint)cm));
                    if (haveHb && armed != lastArmed) RecMsg(t, armed ? "ARMED" : "DISARMED");
                    if (!haveHb) RecMsg(t, $"Початок запису: {(MAV_TYPE)vt}, режим {Mode.Name((byte)vt, (uint)cm)}, {(armed ? "ARMED" : "DISARMED")}");
                    haveHb = true; lastMode = cm; lastArmed = armed;
                    break;
                }
            }
        }
        if (specs.Count == 0) throw new InvalidDataException("tlog порожній");

        // Спец-типи, створені «на льоту» без стовпців
        foreach (var kv in specs.OrderBy(k => k.Value.Type))
        {
            var s = kv.Value; string fmt, labels; int length;
            if (kv.Key == "MSG") { fmt = "QZ"; labels = "TimeUS,Message"; length = 3 + 8 + 64; }
            else if (kv.Key == "PARM") { fmt = "QNd"; labels = "TimeUS,Name,Value"; length = 3 + 8 + 16 + 8; }
            else
            {
                var names = s.Cols.Select(c => c.Name).ToList();
                if (names.Count == 0 || names[0] != "TimeUS") names.Insert(0, "TimeUS");
                fmt = "Q" + new string('d', s.Cols.Count); labels = string.Join(",", names.Take(s.Cols.Count + 1)); length = s.Length;
            }
            var rec = new byte[3 + 1 + 1 + 40 + 24 + 256];
            rec[0] = 0xA3; rec[1] = 0x95; rec[2] = 127; rec[3] = s.Type; rec[4] = (byte)length;
            void Put(string v, int o, int max) { var b = Encoding.ASCII.GetBytes(v); Array.Copy(b, 0, rec, o, Math.Min(b.Length, max)); }
            Put(kv.Key, 5, 40); Put(fmt, 45, 24); Put(labels, 69, 256);
            ms.Write(rec, 0, rec.Length);
        }
        body.WriteTo(ms);
        File.WriteAllBytes(outPath, ms.ToArray());
        return outPath;
    }
}
