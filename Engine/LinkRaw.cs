using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using static MAVLink;

/// Довільні MAVLink-повідомлення за іменем (для розширень) і допоміжні повідомлення для антенного трекера.
/// Поля пакуються вручну за порядком у структурі (рефлексія GetValue/SetValue на packed-структурах небезпечна на Apple Silicon).
partial class Link
{
    int rawSeq;

    /// Повідомлення, які розширення не можуть слати напряму: для них є окремі API з перевірками (команди, параметри, режими, файли, журнали).
    static readonly HashSet<string> RawDeny = new HashSet<string>
    {
        "COMMAND_LONG", "COMMAND_INT", "SET_MODE", "PARAM_SET", "PARAM_EXT_SET", "LOG_ERASE", "LOG_REQUEST_END",
        "FILE_TRANSFER_PROTOCOL", "SERIAL_CONTROL", "FLIGHT_INFORMATION", "AUTH_KEY", "SETUP_SIGNING", "SECURE_COMMAND",
        "MISSION_COUNT", "MISSION_ITEM", "MISSION_ITEM_INT", "MISSION_CLEAR_ALL", "MISSION_WRITE_PARTIAL_LIST", "MISSION_SET_CURRENT",
    };

    static int RawSize(Type t)
    {
        if (t.IsEnum) t = Enum.GetUnderlyingType(t);
        if (t == typeof(byte) || t == typeof(sbyte)) return 1;
        if (t == typeof(short) || t == typeof(ushort)) return 2;
        if (t == typeof(int) || t == typeof(uint) || t == typeof(float)) return 4;
        if (t == typeof(long) || t == typeof(ulong) || t == typeof(double)) return 8;
        return 1;
    }

    static void RawPut(byte[] buf, int off, Type t, double v)
    {
        if (t.IsEnum) t = Enum.GetUnderlyingType(t);
        byte[] b;
        if (t == typeof(byte)) b = new[] { (byte)Math.Clamp(Math.Round(v), 0, 255) };
        else if (t == typeof(sbyte)) b = new[] { unchecked((byte)(sbyte)Math.Clamp(Math.Round(v), -128, 127)) };
        else if (t == typeof(short)) b = BitConverter.GetBytes((short)Math.Clamp(Math.Round(v), short.MinValue, short.MaxValue));
        else if (t == typeof(ushort)) b = BitConverter.GetBytes((ushort)Math.Clamp(Math.Round(v), 0, ushort.MaxValue));
        else if (t == typeof(int)) b = BitConverter.GetBytes((int)Math.Clamp(Math.Round(v), int.MinValue, int.MaxValue));
        else if (t == typeof(uint)) b = BitConverter.GetBytes((uint)Math.Clamp(Math.Round(v), 0, uint.MaxValue));
        else if (t == typeof(long)) b = BitConverter.GetBytes((long)Math.Round(v));
        else if (t == typeof(ulong)) b = BitConverter.GetBytes((ulong)Math.Max(0, Math.Round(v)));
        else if (t == typeof(float)) b = BitConverter.GetBytes((float)v);
        else if (t == typeof(double)) b = BitConverter.GetBytes(v);
        else return;
        Array.Copy(b, 0, buf, off, b.Length);
    }

    static double RawRead(byte[] src, int off, Type t)
    {
        if (t.IsEnum) t = Enum.GetUnderlyingType(t);
        if (off + RawSize(t) > src.Length) return 0;
        if (t == typeof(byte)) return src[off];
        if (t == typeof(sbyte)) return (sbyte)src[off];
        if (t == typeof(short)) return BitConverter.ToInt16(src, off);
        if (t == typeof(ushort)) return BitConverter.ToUInt16(src, off);
        if (t == typeof(int)) return BitConverter.ToInt32(src, off);
        if (t == typeof(uint)) return BitConverter.ToUInt32(src, off);
        if (t == typeof(long)) return BitConverter.ToInt64(src, off);
        if (t == typeof(ulong)) return BitConverter.ToUInt64(src, off);
        if (t == typeof(float)) return BitConverter.ToSingle(src, off);
        if (t == typeof(double)) return BitConverter.ToDouble(src, off);
        return 0;
    }

    static (Type et, int n) FieldShape(System.Reflection.FieldInfo f)
    {
        var ft = f.FieldType;
        if (!ft.IsArray) return (ft, 1);
        var ma = (System.Runtime.InteropServices.MarshalAsAttribute)Attribute.GetCustomAttribute(f, typeof(System.Runtime.InteropServices.MarshalAsAttribute));
        return (ft.GetElementType(), ma != null ? ma.SizeConst : 1);
    }

    /// Збирає й відправляє повідомлення. fields: {"поле": число | [числа] | "рядок"}. Повертає null при успіху або текст помилки.
    public string SendRaw(string name, JsonElement fields, int sys, int comp, bool checkDeny = true)
    {
        name = (name ?? "").ToUpperInvariant();
        if (checkDeny && RawDeny.Contains(name)) return "message denied: " + name;
        var info = MAVLINK_MESSAGE_INFOS.FirstOrDefault(i => i.name == name);
        if (info.type == null) return "unknown message: " + name;
        var fl = info.type.GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);
        int total = 0; foreach (var f in fl) { var (et, n) = FieldShape(f); total += RawSize(et) * n; }
        var data = new byte[total];
        int off = 0;
        foreach (var f in fl)
        {
            var (et, n) = FieldShape(f);
            int sz = RawSize(et);
            if (fields.ValueKind == JsonValueKind.Object && fields.TryGetProperty(f.Name, out var v))
            {
                if (v.ValueKind == JsonValueKind.Number) RawPut(data, off, et, v.GetDouble());
                else if (v.ValueKind == JsonValueKind.True || v.ValueKind == JsonValueKind.False) RawPut(data, off, et, v.GetBoolean() ? 1 : 0);
                else if (v.ValueKind == JsonValueKind.String && f.FieldType.IsArray)
                {
                    var b = Encoding.UTF8.GetBytes(v.GetString() ?? ""); Array.Copy(b, 0, data, off, Math.Min(b.Length, n * sz));
                }
                else if (v.ValueKind == JsonValueKind.Array)
                {
                    int i = 0; foreach (var e in v.EnumerateArray()) { if (i >= n) break; if (e.ValueKind == JsonValueKind.Number) RawPut(data, off + i * sz, et, e.GetDouble()); i++; }
                }
            }
            off += sz * n;
        }
        // MAVLink 2: зайві нулі в кінці payload відкидаються (мінімум 1 байт)
        int len = data.Length; while (len > 1 && data[len - 1] == 0) len--;
        var pk = new byte[len + MAVLINK_NUM_NON_PAYLOAD_BYTES];
        pk[0] = MAVLINK_STX; pk[1] = (byte)len; pk[2] = 0; pk[3] = 0;
        pk[4] = (byte)System.Threading.Interlocked.Increment(ref rawSeq);
        pk[5] = (byte)sys; pk[6] = (byte)comp;
        pk[7] = (byte)info.msgid; pk[8] = (byte)(info.msgid >> 8); pk[9] = (byte)(info.msgid >> 16);
        Array.Copy(data, 0, pk, MAVLINK_NUM_HEADER_BYTES, len);
        ushort ck = MavlinkCRC.crc_calculate(pk, len + MAVLINK_NUM_HEADER_BYTES);
        ck = MavlinkCRC.crc_accumulate(info.crc, ck);
        pk[MAVLINK_NUM_HEADER_BYTES + len] = (byte)(ck & 0xFF);
        pk[MAVLINK_NUM_HEADER_BYTES + len + 1] = (byte)(ck >> 8);
        Send(pk);
        return null;
    }

    /// Останнє отримане повідомлення з іменем у вигляді {поле: значення}; null, якщо ще не було.
    public Dictionary<string, object> GetRaw(string name, out double ageSec)
    {
        ageSec = -1;
        (Type type, byte[] payload) item;
        lock (lk)
        {
            if (!latest.TryGetValue((name ?? "").ToUpperInvariant(), out item)) return null;
            if (msgStats.TryGetValue((name ?? "").ToUpperInvariant(), out var st)) ageSec = (DateTime.UtcNow - st.last).TotalSeconds;
        }
        var res = new Dictionary<string, object>();
        int off = 0;
        foreach (var f in item.type.GetFields(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance))
        {
            var (et, n) = FieldShape(f);
            int sz = RawSize(et);
            if (!f.FieldType.IsArray) res[f.Name] = RawRead(item.payload, off, et);
            else if (et == typeof(byte) && (f.Name == "text" || f.Name.EndsWith("_id") || f.Name == "name" || f.Name == "param_id"))
            {
                var b = item.payload.Skip(off).Take(n).TakeWhile(x => x != 0).ToArray(); res[f.Name] = Encoding.ASCII.GetString(b);
            }
            else res[f.Name] = Enumerable.Range(0, n).Select(i => RawRead(item.payload, off + i * sz, et)).ToArray();
            off += sz * n;
        }
        return res;
    }

    // ---- Антенний трекер (прошивка AntennaTracker) ----

    /// Положення «апарата» для трекера: GLOBAL_POSITION_INT від імені системи sysid (SYSID_TARGET), щоб трекер навівся на цю точку в режимі Auto.
    /// Висота: alt (над рівнем моря, м) для ALT_SOURCE=GPS, rel (над точкою трекера, м) для ALT_SOURCE=«GPS лише апарата».
    public string TrackerPosition(double lat, double lon, double alt, double rel, int sysid)
    {
        if (Math.Abs(lat) < 1e-7 && Math.Abs(lon) < 1e-7) return "lat/lon 0,0 is rejected by the tracker";
        var json = JsonSerializer.SerializeToElement(new Dictionary<string, double>
        {
            ["time_boot_ms"] = (double)(Environment.TickCount64 & 0xFFFFFFF), ["lat"] = lat * 1e7, ["lon"] = lon * 1e7,
            ["alt"] = alt * 1000, ["relative_alt"] = rel * 1000, ["vx"] = 0, ["vy"] = 0, ["vz"] = 0, ["hdg"] = 65535,
        });
        return SendRaw("GLOBAL_POSITION_INT", json, Math.Clamp(sysid, 1, 255), 1, false);
    }

    /// Абсолютний напрям антени в режимі Guided: SET_ATTITUDE_TARGET (yaw = азимут від півночі, pitch = кут місця).
    public string TrackerAim(double az, double el)
    {
        double y = az * Math.PI / 180, p = el * Math.PI / 180;
        double cy = Math.Cos(y / 2), sy = Math.Sin(y / 2), cp = Math.Cos(p / 2), sp = Math.Sin(p / 2);
        // крен = 0: q = Rz(yaw)·Ry(pitch)
        double[] q = { cy * cp, -sy * sp, cy * sp, sy * cp };
        var json = JsonSerializer.SerializeToElement(new Dictionary<string, object>
        {
            ["time_boot_ms"] = (double)(Environment.TickCount64 & 0xFFFFFFF), ["target_system"] = (int)targetSys, ["target_component"] = (int)targetComp,
            ["q"] = q, ["body_roll_rate"] = 0, ["body_pitch_rate"] = 0, ["body_yaw_rate"] = 0, ["thrust"] = 0,
            ["type_mask"] = 65,    // ігнорувати швидкість крену й тягу; швидкості нахилу й азимуту = 0 (прошивка вимагає хоча б одну)
        });
        return SendRaw("SET_ATTITUDE_TARGET", json, Link.GcsId, 190, false);
    }
}
